import Flutter
import Foundation
import NetworkExtension

final class AsterIOSHost {
    static let shared = AsterIOSHost()

    private var hostOpen = false
    // Flutter polls state every two seconds. Without serialization, a poll can
    // reach the in-app host while connect is closing it for the tunnel.
    private let gate = AsterSerialGate()

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
                        result(try await self.gate.run { try await self.handleRequest(value) })
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
                        result(try await self.gate.run { try await self.startTunnel(request: value) })
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "stopVpn":
                Task {
                    do {
                        result(try await self.gate.run { try await self.stopTunnel() })
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "status":
                Task {
                    do {
                        let running = try await self.gate.run { try await self.isTunnelRunning() }
                        result(AsterIOSRuntime.response(id: 0, result: ["running": running]))
                    } catch {
                        result(FlutterError(code: "operation", message: error.localizedDescription, details: nil))
                    }
                }
            case "releaseHost":
                // iOS may suspend the app while the tunnel keeps running. The
                // extension needs the App Group engine lock, so the in-app host
                // is released when the app leaves the foreground.
                Task {
                    try? await self.gate.run { try self.closeHost() }
                    result(nil)
                }
            case "initialRoute":
                let route = UserDefaults.standard.string(forKey: "AsterPendingRoute")
                UserDefaults.standard.removeObject(forKey: "AsterPendingRoute")
                result(route)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let connection = notification.object as? NEVPNConnection,
                  self.isActive(connection) else { return }
            // A tunnel started outside the app (Settings, Control Center, a
            // Shortcut) owns the core from now on.
            Task { try? await self.gate.run { try self.closeHost() } }
        }
    }

    func connectFromIntent() async throws {
        let request = try AsterIOSRuntime.jsonRequest(method: "connect")
        let response = try await gate.run { try await self.startTunnel(request: request) }
        if let message = AsterIOSRuntime.responseError(response) {
            throw AsterIOSError.mobileEngine(message)
        }
    }

    func disconnectFromIntent() async throws {
        _ = try await gate.run { try await self.stopTunnel() }
    }

    func currentStatus() async -> String {
        guard let manager = try? await gate.run({ try await self.tunnelManager() }) else {
            return "Unavailable"
        }
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

    private func isTunnelRunning() async throws -> Bool {
        guard let manager = try await tunnelManager() else { return false }
        return isActive(manager.connection)
    }

    private func handleRequest(_ request: String) async throws -> String {
        let object = try requestObject(request)
        let id = object.id
        let method = object.method
        let manager = try await tunnelManager()
        let running = manager.map { isActive($0.connection) } ?? false

        if method == "disconnect" {
            _ = try await stopTunnel()
            return AsterIOSRuntime.response(id: id, result: true)
        }
        if running, let manager {
            let data = try await sendProviderMessageWhenReady(
                manager: manager,
                request: request
            )
            return String(decoding: data, as: UTF8.self)
        }

        try await openHostIfNeeded()
        do {
            return try AsterIOSRuntime.callHost(request)
        } catch {
            throw AsterIOSError.mobileEngine(error.localizedDescription)
        }
    }

    private func startTunnel(request: String) async throws -> String {
        let object = try requestObject(request)
        var started: NETunnelProviderManager?
        do {
            if let manager = try await tunnelManager(), isActive(manager.connection) {
                let data = try await sendProviderMessageWhenReady(
                    manager: manager,
                    request: request
                )
                return String(decoding: data, as: UTF8.self)
            }
            try await openHostIfNeeded()
            let stateRequest = try AsterIOSRuntime.jsonRequest(method: "state")
            _ = try AsterIOSRuntime.callHost(stateRequest)
            try closeHost()

            let manager = try await preparedTunnelManager()
            started = manager
            try manager.connection.startVPNTunnel()
            try await waitForConnected(manager: manager)

            let data = try await sendProviderMessage(Data(request.utf8))
            return String(decoding: data, as: UTF8.self)
        } catch {
            // A tunnel that came up without a working core would black-hole all
            // traffic and make the next Connect appear to hang.
            if let started, isActive(started.connection) {
                started.connection.stopVPNTunnel()
                await waitForTunnelToStop(manager: started)
            }
            try? await openHostIfNeeded()
            return AsterIOSRuntime.errorResponse(id: object.id, message: error.localizedDescription)
        }
    }

    private func stopTunnel() async throws -> String {
        if let manager = try await tunnelManager() {
            if isActive(manager.connection) {
                let request = try AsterIOSRuntime.jsonRequest(method: "disconnect")
                _ = try? await sendProviderMessage(Data(request.utf8))
                manager.connection.stopVPNTunnel()
            }
            // The provider holds the App Group instance lock until its core is
            // fully stopped. Reopening the in-app host too early fails with the
            // desktop "already running" error.
            await waitForTunnelToStop(manager: manager)
        }
        try await openHostIfNeeded()
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

    private func openHostIfNeeded() async throws {
        if hostOpen { return }
        let directory = try AsterIOSRuntime.containerURL()
        var lastError: Error?
        for attempt in 0..<100 {
            do {
                try AsterIOSRuntime.openHost(directory.path)
                hostOpen = true
                return
            } catch {
                lastError = error
                if attempt < 99 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        throw AsterIOSError.mobileEngine(
            lastError?.localizedDescription ?? "Could not open the mobile engine."
        )
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
        // Right after startVPNTunnel the status can still be .disconnected for a
        // moment. Waiting the full timeout makes a denied or failed start look
        // like a hang, so only allow a short grace period before failing.
        var disconnectedFor = 0
        for _ in 0..<120 {
            switch manager.connection.status {
            case .connected:
                return
            case .invalid, .disconnecting:
                throw AsterIOSError.tunnelStartFailed
            case .disconnected:
                disconnectedFor += 1
                if disconnectedFor >= 12 {
                    throw AsterIOSError.tunnelStartFailed
                }
            default:
                disconnectedFor = 0
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AsterIOSError.tunnelStartTimeout
    }

    private func isActive(_ connection: NEVPNConnection) -> Bool {
        switch connection.status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private func waitForTunnelToStop(manager: NETunnelProviderManager) async {
        for _ in 0..<100 {
            switch manager.connection.status {
            case .disconnected, .invalid:
                return
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func sendProviderMessageWhenReady(
        manager: NETunnelProviderManager,
        request: String
    ) async throws -> Data {
        if manager.connection.status != .connected {
            try await waitForConnected(manager: manager)
        }
        return try await sendProviderMessage(Data(request.utf8))
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

/// Runs host operations one at a time. The Flutter channel, App Intents and
/// polling all reach the same in-process engine and tunnel session.
final class AsterSerialGate {
    private let lock = NSLock()
    private var tail: Task<Void, Never> = Task {}

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        lock.lock()
        let previous = tail
        let work = Task<T, Error> {
            await previous.value
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        lock.unlock()
        return try await work.value
    }
}
