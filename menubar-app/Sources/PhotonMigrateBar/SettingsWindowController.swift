import SwiftUI
import AppKit

/// LSUIElement (menu-bar-only) apps have no standard app menu, so the usual
/// `showSettingsWindow:` trick that opens a SwiftUI `Settings` scene never
/// gets wired up. We open a plain NSWindow ourselves instead.
///
/// Accessory apps (.accessory activation policy) can also fail to give a
/// secondary window real key/focus status -- clicks land, but text fields
/// never actually become first responder. Switching to .regular while this
/// window is open (and back to .accessory when it closes) fixes that.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(state: AppState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView().environmentObject(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Photon Migrate Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(hosting.view)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
