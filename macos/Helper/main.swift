import Foundation
import Security

@objc protocol AsterSupervisorProtocol {
    func request(_ payload: String, withReply reply: @escaping (String) -> Void)
}

final class Supervisor: NSObject, AsterSupervisorProtocol {
    private let queue = DispatchQueue(label: "app.astercore.desktop.supervisor")
    private let stateLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let app = "/Applications/Aster Desktop.app"

    func request(_ payload: String, withReply reply: @escaping (String) -> Void) {
        queue.async {
            guard let bytes = payload.data(using: .utf8), bytes.count <= 16 * 1024 * 1024 + 4096,
                  let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let method = request["method"] as? String,
                  ["status", "start", "stop", "apply", "controller", "logs", "metrics", "updateCore", "proxyStart", "proxyStop"].contains(method)
            else { reply(self.failure("Unsupported service request")); return }
            do {
                let (input, output) = try self.session()
                try input.write(contentsOf: bytes + Data([10]))
                var response = Data()
                while response.count <= 16 * 1024 * 1024 + 4096 {
                    guard let chunk = try output.read(upToCount: 65536), !chunk.isEmpty else { throw NSError(domain: "Aster", code: 2) }
                    response.append(chunk)
                    if let end = response.firstIndex(of: 10) {
                        reply(String(data: response.prefix(upTo: end), encoding: .utf8) ?? self.failure("Invalid response")); return
                    }
                }
                reply(self.failure("Service response exceeded its limit"))
            } catch {
                self.stop()
                reply(self.failure("Background service stopped. Reconnect and try again."))
            }
        }
    }

    private func session() throws -> (FileHandle, FileHandle) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if process?.isRunning == true, let input = input, let output = output { return (input, output) }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: app + "/Contents/Resources/aster-bridge")
        child.arguments = ["--privileged-stdio", "--data", "/Library/Application Support/AsterDesktop/service", "--core", app + "/Contents/Resources/aster-core"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.standardError
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        return (stdin.fileHandleForWriting, stdout.fileHandleForReading)
    }

    func stop() {
        stateLock.lock()
        let child = process, stdin = input
        process = nil
        input = nil
        output = nil
        stateLock.unlock()
        try? stdin?.close()
        if let child = child {
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if child.isRunning { child.terminate() } }
        }
    }
    private func failure(_ message: String) -> String {
        let value: [String: Any] = ["error": ["code": "service", "message": message]]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let connectionLock = NSLock()
    private var active: NSXPCConnection?
    private let supervisor = Supervisor()
    private let trustedExecutable = "/Applications/Aster Desktop.app/Contents/MacOS/Aster Desktop"

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard active == nil, trustedInstallation(), trustedPeer(connection.processIdentifier) else { return false }
        active = connection
        connection.exportedInterface = NSXPCInterface(with: AsterSupervisorProtocol.self)
        connection.exportedObject = supervisor
        connection.invalidationHandler = { [weak self] in
            guard let self = self else { return }
            self.connectionLock.lock()
            self.supervisor.stop()
            self.active = nil
            self.connectionLock.unlock()
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    private func trustedInstallation() -> Bool {
        for path in ["/Applications/Aster Desktop.app", "/Applications/Aster Desktop.app/Contents", "/Applications/Aster Desktop.app/Contents/MacOS", trustedExecutable,
                     "/Applications/Aster Desktop.app/Contents/Resources", "/Applications/Aster Desktop.app/Contents/Resources/aster-bridge", "/Applications/Aster Desktop.app/Contents/Resources/aster-core"] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o022 == 0,
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
        }
        return true
    }

    private func trustedPeer(_ pid: pid_t) -> Bool {
        var guest: SecCode?, trusted: SecStaticCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest = guest,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: trustedExecutable) as CFURL, [], &trusted) == errSecSuccess,
              let trusted = trusted,
              SecCodeCopyDesignatedRequirement(trusted, [], &requirement) == errSecSuccess,
              let requirement = requirement,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }
        var information: CFDictionary?, guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess,
              let guestStatic = guestStatic,
              SecCodeCopySigningInformation(guestStatic, [], &information) == errSecSuccess,
              let values = information as? [String: Any],
              let path = values[kSecCodeInfoMainExecutable as String] as? URL else { return false }
        return path.resolvingSymlinksInPath().path == trustedExecutable
    }
}

let listener = NSXPCListener(machServiceName: "app.astercore.desktop.helper")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
