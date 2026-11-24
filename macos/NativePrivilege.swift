import AppKit
import Darwin
import Foundation
import ServiceManagement

// Matches the existing authenticated helper and keeps the XPC peer inside the
// signed application executable. Go calls this API from worker goroutines.
@objc protocol AsterSupervisorProtocol {
    func request(_ payload: String, withReply reply: @escaping (String) -> Void)
}

private let service = SMAppService.daemon(plistName: "app.astercore.desktop.helper.plist")
private let connectionLock = NSLock()
private var connection: NSXPCConnection?

private func supervisorConnection() -> NSXPCConnection {
    connectionLock.lock()
    defer { connectionLock.unlock() }
    if let connection { return connection }
    let client = NSXPCConnection(machServiceName: "app.astercore.desktop.helper", options: .privileged)
    client.remoteObjectInterface = NSXPCInterface(with: AsterSupervisorProtocol.self)
    client.invalidationHandler = { [weak client] in
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if connection === client { connection = nil }
    }
    client.resume()
    connection = client
    return client
}

private func closeConnection() {
    connectionLock.lock()
    let previous = connection
    connection = nil
    connectionLock.unlock()
    previous?.invalidate()
}

private final class Reply {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: String?

    func finish(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if result == nil {
            result = text
            ready.signal()
        }
    }

    func wait(seconds: Int) -> String? {
        if ready.wait(timeout: .now() + .seconds(seconds)) != .success { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private func encode(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

@MainActor
private func applicationIcons(_ paths: [String]) -> [String: String] {
    var icons: [String: String] = [:]
    var budget = 1_048_576
    for path in paths.prefix(256) {
        guard path.hasPrefix("/"), let suffix = path.range(of: ".app/Contents/", options: .backwards) else { continue }
        let bundle = String(path[..<suffix.lowerBound]) + ".app"
        autoreleasepool {
            let image = NSWorkspace.shared.icon(forFile: bundle)
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]), png.count <= 32768, png.count <= budget {
                icons[path] = png.base64EncodedString()
                budget -= png.count
            }
        }
    }
    return icons
}

@_cdecl("aster_privilege_request")
public func asterPrivilegeRequest(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let text = String(cString: request)
    guard let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let id = payload["id"] as? UInt64,
          let method = payload["method"] as? String else { return nil }
    func success(_ value: Any) -> String { encode(["id": id, "result": value]) }
    func failure(_ message: String) -> String {
        encode(["id": id, "error": ["code": "service", "message": message]])
    }
    switch method {
    case "applicationIcons":
        let paths = payload["params"] as? [String] ?? []
        let reply = Reply()
        DispatchQueue.main.async { reply.finish(success(applicationIcons(paths))) }
        return strdup(reply.wait(seconds: 10) ?? success([String: String]()))
    case "serviceStatus":
        return strdup(success(["installed": service.status != .notRegistered, "approved": service.status == .enabled, "platform": "macos"]))
    case "installService":
        do {
            if service.status == .notRegistered { try service.register() }
            if service.status == .requiresApproval {
                DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
            }
            return strdup(success(true))
        } catch {
            return strdup(failure("Install Aster Desktop from its package, then approve the background service in System Settings. " + error.localizedDescription))
        }
    case "uninstallService":
        closeConnection()
        let reply = Reply()
        service.unregister { error in
            if let error { reply.finish(failure(error.localizedDescription)) }
            else { reply.finish(success(true)) }
        }
        return strdup(reply.wait(seconds: 30) ?? failure("Removing the background service timed out."))
    case "close":
        closeConnection()
        return strdup(success(true))
    default:
        guard service.status == .enabled else {
            return strdup(failure("Install and approve the background service in Advanced settings."))
        }
    }
    let client = supervisorConnection()
    let reply = Reply()
    guard let remote = client.remoteObjectProxyWithErrorHandler({ error in
        reply.finish(failure("Background service is unavailable. " + error.localizedDescription))
    }) as? AsterSupervisorProtocol else {
        return strdup(failure("Background service is unavailable."))
    }
    remote.request(text) { response in reply.finish(response) }
    if let response = reply.wait(seconds: method == "updateCore" ? 600 : 120) {
        return strdup(response)
    }
    return strdup(failure("The background service did not respond in time."))
}

@_cdecl("aster_privilege_free")
public func asterPrivilegeFree(_ response: UnsafeMutablePointer<CChar>?) {
    free(response)
}
