import Foundation
import Mobileapi

enum AsterIOSRuntime {
    static let appGroup = "group.app.aster.desktop"
    static let tunnelBundleIdentifier = "app.aster.desktop.tunnel"
    static let providerMessageMethod = "app.aster.tunnel"

    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            throw AsterIOSError.appGroupUnavailable
        }
        let data = url.appendingPathComponent("AsterData", isDirectory: true)
        try FileManager.default.createDirectory(
            at: data,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return data
    }

    static func jsonRequest(id: Int = 0, method: String, params: Any = [:]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "method": method,
            "params": params,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    static func response(id: Int, result: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [
            "id": id,
            "result": result,
        ])) ?? Data(#"{"id":0,"result":false}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func errorResponse(id: Int, message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [
            "id": id,
            "error": ["code": "operation", "message": message],
        ])) ?? Data(#"{"id":0,"error":{"message":"operation failed"}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func responseError(_ response: String) -> String? {
        guard let data = response.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String ?? "The mobile engine rejected the request."
    }

    static func openHost(_ path: String) throws {
        var error: NSError?
        if !MobileapiOpenHost(path, &error) {
            throw error ?? AsterIOSError.mobileEngine("Could not open the mobile engine.")
        }
    }

    static func closeHost() throws {
        var error: NSError?
        if !MobileapiCloseHost(&error) {
            throw error ?? AsterIOSError.mobileEngine("Could not close the mobile engine.")
        }
    }

    static func callHost(_ request: String) throws -> String {
        var error: NSError?
        let response = MobileapiCallHost(request, &error)
        if let error { throw error }
        return response
    }

    static func startHostVPN(fd: Int32, options: String = "") throws -> String {
        var error: NSError?
        let response = MobileapiStartHostVPN(fd, options, &error)
        if let error { throw error }
        return response
    }

    static func stopHostVPN() throws -> String {
        var error: NSError?
        let response = MobileapiStopHostVPN(&error)
        if let error { throw error }
        return response
    }
}

enum AsterIOSError: LocalizedError {
    case appGroupUnavailable
    case mobileEngine(String)
    case tunnelUnavailable
    case tunnelStartTimeout
    case tunnelStartFailed
    case tunnelStopped
    case tunnelFileDescriptor
    case invalidProviderReply
    case tunnelReplyTimeout

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Aster App Group is unavailable."
        case .mobileEngine(let message):
            return message
        case .tunnelUnavailable:
            return "Aster NetworkExtension is unavailable."
        case .tunnelStartTimeout:
            return "Aster VPN did not become ready in time."
        case .tunnelStartFailed:
            return "Aster VPN failed to start. Check that no other VPN is active and that Aster is allowed to use VPN."
        case .tunnelStopped:
            return "Aster VPN was stopped before it finished starting."
        case .tunnelFileDescriptor:
            return "iOS did not expose the tunnel packet descriptor."
        case .invalidProviderReply:
            return "Aster NetworkExtension returned an invalid reply."
        case .tunnelReplyTimeout:
            return "Aster VPN did not reply in time. Disconnect and connect again."
        }
    }
}
