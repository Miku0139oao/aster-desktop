import Foundation

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
}

enum AsterIOSError: LocalizedError {
    case appGroupUnavailable
    case mobileEngine(String)
    case tunnelUnavailable
    case tunnelStartTimeout
    case tunnelFileDescriptor
    case invalidProviderReply

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Aster App Group is unavailable."
        case .mobileEngine(let message):
            return message
        case .tunnelUnavailable:
            return "Aster NetworkExtension is unavailable."
        case .tunnelStartTimeout:
            return "Aster VPN did not become ready."
        case .tunnelFileDescriptor:
            return "iOS did not expose the tunnel packet descriptor."
        case .invalidProviderReply:
            return "Aster NetworkExtension returned an invalid reply."
        }
    }
}
