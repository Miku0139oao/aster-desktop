import Darwin
import Foundation
import NetworkExtension

final class AsterTunnelProvider: NEPacketTunnelProvider {
    private var hostOpen = false
    // The provider receives App messages on the system queue while the tunnel
    // is starting on the settings callback. Both touch the same Go engine, so
    // every access is serialized here.
    private let engineQueue = DispatchQueue(label: "app.aster.desktop.tunnel.engine")

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = packetTunnelSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            self.engineQueue.async {
                do {
                    try self.startMobileCore()
                    completionHandler(nil)
                } catch {
                    self.closeMobileCore()
                    completionHandler(error)
                }
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        engineQueue.async {
            self.closeMobileCore()
            completionHandler()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        engineQueue.async { [weak self] in
            guard let self else {
                completionHandler?(nil)
                return
            }
            do {
                let request = String(decoding: messageData, as: UTF8.self)
                let response = try AsterIOSRuntime.callHost(request)
                completionHandler?(Data(response.utf8))
            } catch {
                let response = AsterIOSRuntime.errorResponse(
                    id: 0,
                    message: error.localizedDescription
                )
                completionHandler?(Data(response.utf8))
            }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}

    private func startMobileCore() throws {
        let directory = try AsterIOSRuntime.containerURL()
        // The app may still be releasing its in-app host (for example when the
        // tunnel is started from Settings or Control Center). The App Group
        // engine lock is exclusive, so retry briefly before failing.
        var lastError: Error?
        for attempt in 0..<50 {
            do {
                try AsterIOSRuntime.openHost(directory.path)
                hostOpen = true
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < 49 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        if !hostOpen {
            throw AsterIOSError.mobileEngine(
                lastError?.localizedDescription ?? "Could not open the mobile engine."
            )
        }
        guard let fd = tunnelFileDescriptor() else {
            throw AsterIOSError.tunnelFileDescriptor
        }
        // iOS tunnels have no Android package selectors. Pass empty routing so
        // the core does not inherit selectors saved by another platform.
        let options = #"{"includePackages":[],"excludePackages":[]}"#
        let response = try AsterIOSRuntime.startHostVPN(fd: fd, options: options)
        if let error = AsterIOSRuntime.responseError(response) {
            throw AsterIOSError.mobileEngine(error)
        }
    }

    private func closeMobileCore() {
        if hostOpen {
            _ = try? AsterIOSRuntime.stopHostVPN()
            try? AsterIOSRuntime.closeHost()
            hostOpen = false
        }
    }

    private func packetTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.2")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00:a57e:0:1::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [.default()]
        settings.ipv6Settings = ipv6

        settings.dnsSettings = NEDNSSettings(servers: [
            "198.18.0.2",
            "fd00:a57e:0:1::2",
        ])
        settings.mtu = NSNumber(value: 9000)
        return settings
    }

    private func tunnelFileDescriptor() -> Int32? {
        let sysprotoControl: Int32 = 2
        let utunOptIfname: Int32 = 2
        for fd in Int32(0)..<Int32(1024) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            let result = getsockopt(
                fd,
                sysprotoControl,
                utunOptIfname,
                &name,
                &length
            )
            if result == 0 && String(cString: name).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }
}
