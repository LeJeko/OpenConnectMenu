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
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = L("OpenConnectMenu Settings")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(host.view.fittingSize)   // final size before positioning, so the top edge stays where it is put
        // The window reopens where it was left; the first time (or if that place is no longer on a screen), at the top
        // center of the screen. The delegate is set afterwards: only a move by the user is remembered.
        if let origin = rememberedOrigin(for: w) { w.setFrameOrigin(origin) } else { placeAtTopCenter(w) }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.delegate = self
    }

    private static let originKey = "settingsWindowOrigin"

    /// The last position chosen by the user, if a screen still shows that part of the window.
    private func rememberedOrigin(for w: NSWindow) -> NSPoint? {
        guard let text = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        let origin = NSPointFromString(text)
        let frame = NSRect(origin: origin, size: w.frame.size)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 100 && $0.visibleFrame.intersection(frame).height >= 50 }
        return onScreen ? origin : nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: Self.originKey)
    }

    private func placeAtTopCenter(_ w: NSWindow) {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { w.center(); return }
        w.setFrameTopLeftPoint(NSPoint(x: area.midX - w.frame.width / 2, y: area.maxY - 24))
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { window = nil }
    }
}
