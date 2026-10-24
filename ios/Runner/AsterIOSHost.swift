import Flutter
import Foundation
import NetworkExtension

final class AsterIOSHost {
    static let shared = AsterIOSHost()

    private var hostOpen = false

    private init() {}

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "app.astercore/ios",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            switch call.method {
            case "call":
                guard let request = call.arguments as? [String: Any],
                      let value = request["request"] as? String else {
                    result(FlutterError(code: "bad_request", message: "Missing request", details: nil))
                    return
                }
                Task {
                    do {
                        result(try await self.handleRequest(value))
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "startVpn":
                guard let request = call.arguments as? [String: Any],
                      let value = request["request"] as? String else {
                    result(FlutterError(code: "bad_request", message: "Missing request", details: nil))
                    return
                }
                Task {
                    do {
                        result(try await self.startTunnel(request: value))
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "stopVpn":
                Task {
                    do {
                        result(try await self.stopTunnel())
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "status":
                Task {
                    do {
                        let manager = try await self.tunnelManager()
                        let running = manager?.connection.status == .connected
                        result(AsterIOSRuntime.response(id: 0, result: ["running": running]))
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "initialRoute":
                let route = UserDefaults.standard.string(forKey: "AsterPendingRoute")
                UserDefaults.standard.removeObject(forKey: "AsterPendingRoute")
                result(route)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func connectFromIntent() async throws {
        let request = try AsterIOSRuntime.jsonRequest(method: "connect")
        _ = try await startTunnel(request: request)
    }

    func disconnectFromIntent() async throws {
        _ = try await stopTunnel()
    }

    func currentStatus() async -> String {
        guard let manager = try? await tunnelManager() else { return "Unavailable" }
        switch manager.connection.status {
        case .connected:
            return "Connected"
        case .connecting, .reasserting:
            return "Connecting"
        case .disconnecting:
            return "Disconnecting"
        default:
            return "Disconnected"
        }
    }

    private func handleRequest(_ request: String) async throws -> String {
        let object = try requestObject(request)
        let id = object.id
        let method = object.method
        let manager = try await tunnelManager()
        let running = manager?.connection.status == .connected ||
            manager?.connection.status == .connecting ||
            manager?.connection.status == .reasserting

        if method == "disconnect" {
            _ = try await stopTunnel()
            return AsterIOSRuntime.response(id: id, result: true)
        }
        if running {
            let data = try await sendProviderMessage(Data(request.utf8))
            return String(decoding: data, as: UTF8.self)
        }

        try openHostIfNeeded()
        do {
            return try AsterIOSRuntime.callHost(request)
        } catch {
            throw AsterIOSError.mobileEngine(error.localizedDescription)
        }
    }

    private func startTunnel(request: String) async throws -> String {
        let object = try requestObject(request)
        do {
            try openHostIfNeeded()
            let stateRequest = try AsterIOSRuntime.jsonRequest(method: "state")
            _ = try AsterIOSRuntime.callHost(stateRequest)
            try closeHost()

            let manager = try await preparedTunnelManager()
            try manager.connection.startVPNTunnel()
            try await waitForConnected(manager: manager)

            let data = try await sendProviderMessage(Data(request.utf8))
            return String(decoding: data, as: UTF8.self)
        } catch {
            try? openHostIfNeeded()
            return AsterIOSRuntime.errorResponse(id: object.id, message: error.localizedDescription)
        }
    }

    private func stopTunnel() async throws -> String {
        if let manager = try await tunnelManager() {
            if manager.connection.status == .connected ||
                manager.connection.status == .connecting ||
                manager.connection.status == .reasserting {
                let request = try AsterIOSRuntime.jsonRequest(method: "disconnect")
                _ = try? await sendProviderMessage(Data(request.utf8))
                manager.connection.stopVPNTunnel()
            }
        }
        try? openHostIfNeeded()
        return #"{"result":true}"#
    }

    private func requestObject(_ request: String) throws -> (id: Int, method: String) {
        let data = Data(request.utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? Int,
              let method = root["method"] as? String else {
            throw AsterIOSError.invalidProviderReply
        }
        return (id, method)
    }

    private func openHostIfNeeded() throws {
        if hostOpen { return }
        let directory = try AsterIOSRuntime.containerURL()
        do {
            try AsterIOSRuntime.openHost(directory.path)
            hostOpen = true
        } catch {
            throw AsterIOSError.mobileEngine(error.localizedDescription)
        }
    }

    private func closeHost() throws {
        guard hostOpen else { return }
        do {
            try AsterIOSRuntime.closeHost()
            hostOpen = false
        } catch {
            throw AsterIOSError.mobileEngine(error.localizedDescription)
        }
    }

    private func tunnelManager() async throws -> NETunnelProviderManager? {
        let managers = try await loadManagers()
        return managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == AsterIOSRuntime.tunnelBundleIdentifier
        }
    }

    private func preparedTunnelManager() async throws -> NETunnelProviderManager {
        let manager = try await tunnelManager() ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = AsterIOSRuntime.tunnelBundleIdentifier
        configuration.serverAddress = "198.18.0.2"
        configuration.providerConfiguration = [
            "appGroup": AsterIOSRuntime.appGroup,
        ]
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Aster"
        manager.isEnabled = true
        try await save(manager)
        try await reload(manager)
        return manager
    }

    private func waitForConnected(manager: NETunnelProviderManager) async throws {
        for _ in 0..<120 {
            if manager.connection.status == .connected { return }
            if manager.connection.status == .invalid { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AsterIOSError.tunnelStartTimeout
    }

    private func sendProviderMessage(_ data: Data) async throws -> Data {
        guard let manager = try await tunnelManager(),
              let session = manager.connection as? NETunnelProviderSession else {
            throw AsterIOSError.tunnelUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    guard let response else {
                        continuation.resume(throwing: AsterIOSError.invalidProviderReply)
                        return
                    }
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
