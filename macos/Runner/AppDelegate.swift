import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // LaunchServices reuses the process and does not call Dart main again.
    if let window = mainFlutterWindow {
      window.deminiaturize(nil)
      window.makeKeyAndOrderFront(nil)
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
