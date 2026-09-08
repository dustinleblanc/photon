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
            // Reads the live upload progress while a batch is running --
            // the label re-renders on @Published changes even while the
            // popover is closed, which the pending count alone did not do
            // (it was only refreshed when the popover opened).
            Text(menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarTitle: String {
        guard state.hasSession else { return "…" }
        if state.isUploading, let progress = state.uploadProgress {
            return progress.menuBarLabel
        }
        return "\(state.counts.pending)"
    }
}
