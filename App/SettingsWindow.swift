import AppKit
import SwiftUI

/// La fenêtre des réglages. Une seule à la fois. Une fois fermée (pastille rouge, Enregistrer ou Annuler) elle est
/// abandonnée et la suivante est recréée : les réglages sont relus à chaque ouverture. Sans cela, la fenêtre fermée
/// puis rouverte réaffichait l'état du premier affichage, par exemple sans la configuration d'un profil installé
/// entre-temps.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let general: GeneralActions?

    init(general: GeneralActions? = nil) {
        self.general = general
    }

    /// Ouvre les réglages, sur la configuration `id` si elle est donnée.
    /// Une fenêtre déjà ouverte est simplement ramenée devant (pour ne pas perdre une saisie en cours), sauf si l'on
    /// demande une configuration précise : elle est alors recréée.
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
