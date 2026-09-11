import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // The app menu's Settings… item lands here via the responder chain
  // (target First Responder). The Flutter engine isn't up when the nib
  // loads, so the view controller is resolved lazily at click time rather
  // than cached during nib awakening.
  @objc func openSettings(_ sender: Any?) {
    let window = NSApp.windows.first { $0 is MainFlutterWindow }
    guard let vc = window?.contentViewController as? FlutterViewController else {
      NSLog("PhotonApp: no Flutter view controller for openSettings")
      return
    }
    FlutterMethodChannel(
      name: "photon/app",
      binaryMessenger: vc.engine.binaryMessenger
    ).invokeMethod("openSettings", arguments: nil)
  }
}
