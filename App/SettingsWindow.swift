import AppKit
import SwiftUI

/// The settings window. Only one at a time. Once closed (red button, Save or Cancel) it is
/// discarded and the next one is recreated: the settings are re-read on every open. Without this, the window, once closed
/// and reopened, showed the state of its first display, for example without the configuration of a profile installed
/// in the meantime.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let general: GeneralActions?

    init(general: GeneralActions? = nil) {
        self.general = general
    }

    /// Opens the settings, on configuration `id` if given.
    /// A window that is already open is simply brought to the front (so as not to lose input in progress), unless a
    /// specific configuration is requested: it is then recreated.
    func show(store: ConfigStore = .shared, selecting id: String? = nil) {
        if let w = window, w.isVisible, id == nil {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        window?.close()

        let view = SettingsView(store: store, selecting: id, general: general) { [weak self] in self?.window?.close() }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = L("VPN Settings")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { window = nil }
    }
}
