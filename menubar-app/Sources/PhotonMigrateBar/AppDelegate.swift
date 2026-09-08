import AppKit

/// Terminates a running upload when the app quits normally. This is the
/// polite half of the story -- a force-quit or crash never runs this, which
/// is why the Go side also watches for its parent disappearing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            state?.cancelUpload()
        }
    }
}
