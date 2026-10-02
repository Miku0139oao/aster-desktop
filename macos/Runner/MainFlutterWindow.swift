import Cocoa
import FlutterMacOS
import ServiceManagement

@objc protocol AsterSupervisorProtocol {
  func request(_ payload: String, withReply reply: @escaping (String) -> Void)
}

class MainFlutterWindow: NSWindow {
  private var privilegeChannel: FlutterMethodChannel?
  private var serviceConnection: NSXPCConnection?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    privilegeChannel = FlutterMethodChannel(name: "app.astercore/privilege", binaryMessenger: flutterViewController.engine.binaryMessenger)
    privilegeChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let service = SMAppService.daemon(plistName: "app.astercore.desktop.helper.plist")
      switch call.method {
      case "serviceStatus":
        result(["installed": service.status != .notRegistered, "approved": service.status == .enabled, "platform": "macos"])
      case "installService":
        do {
          if service.status == .notRegistered { try service.register() }
          if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
          result(true)
        } catch { result(FlutterError(code: "permission", message: "Install the application from its package, then approve the background service in System Settings.", details: error.localizedDescription)) }
      case "uninstallService":
        self.serviceConnection?.invalidate()
        self.serviceConnection = nil
        service.unregister { error in
          DispatchQueue.main.async {
            if let error = error { result(FlutterError(code: "permission", message: error.localizedDescription, details: nil)) } else { result(true) }
          }
        }
      case "serviceCall":
        var completed = false
        let finish: (Any?) -> Void = { value in
          DispatchQueue.main.async {
            guard !completed else { return }
            completed = true
            result(value)
          }
        }
        guard service.status == .enabled, let payload = call.arguments as? String else {
          finish(FlutterError(code: "permission", message: "Install and approve the background service in Advanced settings.", details: nil)); return
        }
        if self.serviceConnection == nil {
          let connection = NSXPCConnection(machServiceName: "app.astercore.desktop.helper", options: .privileged)
          connection.remoteObjectInterface = NSXPCInterface(with: AsterSupervisorProtocol.self)
          connection.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.serviceConnection = nil } }
          connection.resume()
          self.serviceConnection = connection
        }
        guard let proxy = self.serviceConnection?.remoteObjectProxyWithErrorHandler({ error in
          finish(FlutterError(code: "service", message: "Background service is unavailable. Reinstall or authorize it in Advanced settings.", details: error.localizedDescription))
        }) as? AsterSupervisorProtocol else { finish(FlutterError(code: "service", message: "Background service is unavailable.", details: nil)); return }
        proxy.request(payload) { response in finish(response) }
      default: result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
