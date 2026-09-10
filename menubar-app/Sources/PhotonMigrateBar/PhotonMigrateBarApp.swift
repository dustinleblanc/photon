import SwiftUI

@main
struct PhotonMigrateBarApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .onAppear { appDelegate.state = state }
        } label: {
            // A donut progress ring around a camera glyph. The icon re-renders
            // on @Published changes (counts / uploadProgress / isUploading)
            // even while the popover is closed, so progress stays live.
            Image(nsImage: MenuBarIcon.progress(fraction: menuBarFraction))
                .accessibilityLabel("Photon Migrate")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarFraction: Double {
        // While a batch runs, show its live fraction; otherwise fall back to
        // overall library completion (uploaded / total so far).
        if state.isUploading, let progress = state.uploadProgress {
            return progress.fraction
        }
        let c = state.counts
        let total = c.pending + c.uploaded + c.skippedDuplicate + c.failed
        guard total > 0 else { return 0 }
        return Double(c.uploaded) / Double(total)
    }
}
