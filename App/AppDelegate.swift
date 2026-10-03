import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = HelperClient()
    private let helperService = SMAppService.daemon(plistName: Constants.helperPlist)

    private var status: VPNStatus?
    private var trust: TrustInfo?
    private var busy: String?
    private var lastError: String?
    private var timer: Timer?
    private lazy var settingsWindow = SettingsWindowController(general: makeGeneralActions())

    // Helper enregistré mais injoignable (après un crash, une mise à jour, une panne du service système…)
    private var unreachableCount = 0
    private var helperUnreachable = false
    private var repairAttempted = false
    private var repairing = false

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        registerHelperIfNeeded()
        updateIcon()
        Task { await checkHelperVersion() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func registerHelperIfNeeded() {
        if helperService.status == .notRegistered {
            do { try helperService.register() } catch { lastError = L("Helper activation: %@", error.localizedDescription) }
        }
    }

    /// Si un ancien helper tourne encore après une mise à jour, on le relance.
    private func checkHelperVersion() async {
        guard helperService.status == .enabled, let v = await client.version(), v != buildStamp else { return }
        client.quit()
    }

    // MARK: - État

    private func refresh() {
        updateIcon()
        guard helperService.status == .enabled else {
            unreachableCount = 0
            helperUnreachable = false
            return
        }
        Task { @MainActor in
            guard let s = await client.status() else {
                noteUnreachable()
                updateIcon()
                return
            }
            status = s
            unreachableCount = 0
            helperUnreachable = false
            if let t = await client.trustInfo() { trust = t }
            updateIcon()
        }
    }

    /// Le service est « activé » pour macOS mais ne répond pas. On attend quelques relevés (≈ 15 s) avant
    /// de conclure : le helper est lancé à la demande et peut être lent à répondre (réveil de veille…).
    private func noteUnreachable() {
        guard busy == nil, !repairing else { return }
        unreachableCount += 1
        guard unreachableCount >= 5, !helperUnreachable else { return }
        helperUnreachable = true
        let vpnWasUp = status?.connected == true
        status = nil
        // Réparation automatique, une seule fois, sauf si un VPN était actif : la réparation le
        // couperait. Dans ce cas, l'entrée de menu « Repair helper… » reste disponible.
        if !repairAttempted && !vpnWasUp {
            repairAttempted = true
            Task { @MainActor in await repairHelper(automatic: true) }
        }
    }

    /// Réenregistre le helper (désinscription puis inscription), sans privilège : relance le service
    /// auprès de launchd et remplace un ancien processus. L'approbation de l'utilisateur est conservée.
    @MainActor
    private func repairHelper(automatic: Bool) async {
        guard !repairing else { return }
        repairing = true
        busy = L("Repairing helper…")
        updateIcon()
        client.reset()
        try? await helperService.unregister()   // peut échouer si launchd l'a déjà retiré : sans importance
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var failure: String?
        do { try helperService.register() } catch { failure = error.localizedDescription }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        busy = nil
        repairing = false
        unreachableCount = 0
        helperUnreachable = false
        status = nil
        trust = nil
        if let failure {
            lastError = L("Helper repair: %@", failure)
            if !automatic { alert(L("Could not repair the helper"), failure) }
        }
        if !automatic && helperService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        updateIcon()
        refresh()
    }

    private func updateIcon() {
        let name: String
        if busy != nil { name = "lock.rotation" }
        else if status?.connected == true { name = "lock.shield.fill" }
        else { name = "lock.slash" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "VPN")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && (action != nil)
            menu.addItem(item)
            return item
        }

        let helperState = helperService.status
        if let busy {
            add(busy)
        } else if !Homebrew.openConnectInstalled {
            // Détecté côté app, avant même l'autorisation de l'assistant.
            add(L("openconnect is not installed"))
            menu.addItem(.separator())
            add(L("Copy install command…"), #selector(showInstallCommand))
        } else if helperState == .requiresApproval {
            add(L("Helper needs approval in System Settings"))
            menu.addItem(.separator())
            add(L("Open Login Items…"), #selector(openLoginItems))
        } else if helperState != .enabled {
            add(L("Helper not enabled"))
            menu.addItem(.separator())
            add(L("Enable helper…"), #selector(activateHelper))
        } else if helperUnreachable {
            add(L("Helper not reachable"))
            menu.addItem(.separator())
            add(L("Repair helper…"), #selector(repairHelperAction))
        } else if let trust, !trust.trusted {
            add(HelperText.localized(trust.code))
            menu.addItem(.separator())
            if trust.openconnectPath.isEmpty {
                // Rien à approuver : openconnect (ou son vpnc-script) est introuvable.
                add(L("Copy install command…"), #selector(showInstallCommand))
            } else {
                add(L("Approve openconnect…"), #selector(approveTrust))
            }
        } else if let s = status, s.connected {
            // Avec plusieurs configurations, on indique laquelle est connectée.
            let store = ConfigStore.shared
            if store.configs().count > 1, let id = store.activeID, let name = store.config(id: id)?.name {
                add(L("VPN: connected to %@", name))
            } else {
                add(L("VPN: connected"))
            }
            add(L("Address: %@", s.tunnelIP), nil)
            add(L("Since: %@", format(uptime: s.uptime)), nil)
            menu.addItem(.separator())
            add(L("Disconnect"), #selector(disconnect))
        } else {
            add(L("VPN: disconnected"))
            menu.addItem(.separator())
            // Une entrée par configuration ; avec une seule (ou aucune : on ouvre alors les réglages), « Se connecter ».
            let usable = ConfigStore.shared.menuConfigs()
            if usable.count > 1 {
                for c in usable {
                    add(L("Connect to %@", c.name), #selector(connectConfig(_:))).representedObject = c.id
                }
            } else {
                add(L("Connect"), #selector(connectConfig(_:))).representedObject = usable.first?.id
            }
        }

        if let lastError, busy == nil {
            menu.addItem(.separator())
            add("⚠️ " + lastError.split(separator: "\n").first.map(String.init)!, nil)
        }

        menu.addItem(.separator())
        add(L("Settings…"), #selector(openSettings))
        menu.addItem(.separator())
        add(L("Quit"), #selector(NSApplication.terminate(_:)))
        menu.items.last?.target = NSApp
    }

    private func format(uptime: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: uptime) ?? "—"
    }

    // MARK: - Actions

    @objc private func connectConfig(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        guard let id, let request = ConfigStore.shared.request(for: id) else {
            showSettings(selecting: id)   // il manque quelque chose : on ouvre les réglages sur cette configuration
            return
        }
        ConfigStore.shared.activeID = id
        lastError = nil
        busy = L("Connecting…")
        updateIcon()
        Task { @MainActor in
            let (ok, code) = await client.connect(request)
            busy = nil
            if !ok {
                let message = HelperText.localized(code)
                lastError = message
                alert(L("Connection failed"), message)
            }
            if let s = await client.status() { status = s }
            updateIcon()
        }
    }

    @objc private func disconnect() {
        lastError = nil
        busy = L("Disconnecting…")
        updateIcon()
        Task { @MainActor in
            let (ok, code) = await client.disconnect()
            busy = nil
            if !ok {
                let message = HelperText.localized(code)
                lastError = message
                alert(L("Disconnection failed"), message)
            }
            if let s = await client.status() { status = s }
            updateIcon()
        }
    }

    @objc private func approveTrust() {
        guard let trust else { return }
        let a = NSAlert()
        a.messageText = L("Approve openconnect?")
        a.informativeText = L("The helper, which runs as administrator, will only run this version:\n\n%@\nversion %@\n\nIf Homebrew updates it, you will need to approve it again. The Homebrew libraries openconnect uses are not verified.",
                              trust.openconnectPath, trust.version)
        a.addButton(withTitle: L("Approve"))
        a.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let auth = AdminAuth.externalForm() else { return }
        Task { @MainActor in
            let (ok, code) = await client.trust(authorization: auth)
            if !ok { alert(L("Approval refused"), HelperText.localized(code)) }
            refresh()
        }
    }

    @objc private func showInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Homebrew.installCommand, forType: .string)
        let a = NSAlert()
        a.messageText = L("Command copied")
        a.informativeText = Homebrew.brewInstalled
            ? L("Open Terminal, paste the command (⌘V) and press Return:\n\n%@\n\nThen reopen this menu.", Homebrew.installCommand)
            : L("Homebrew is not installed. Install it first from %@, then open Terminal, paste the command (⌘V) and press Return:\n\n%@\n\nThen reopen this menu.", Homebrew.website, Homebrew.installCommand)
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc private func activateHelper() {
        do { try helperService.register() } catch { alert(L("Could not enable the helper"), error.localizedDescription) }
        if helperService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func repairHelperAction() {
        repairAttempted = true
        Task { @MainActor in await repairHelper(automatic: false) }
    }

    private func uninstallHelper() {
        client.quit()
        do { try helperService.unregister() } catch { alert(L("Could not uninstall the helper"), error.localizedDescription) }
        status = nil
        trust = nil
        updateIcon()
    }

    private func setLoginItem(_ on: Bool) {
        let s = SMAppService.mainApp
        do { if on { try s.register() } else { try s.unregister() } }
        catch { alert(L("Could not change the login item"), error.localizedDescription) }
    }

    private func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Constants.logPath))
    }

    /// Ce que l'onglet « Général » des réglages lit et déclenche : les anciennes entrées du menu.
    private func makeGeneralActions() -> GeneralActions {
        GeneralActions(
            helperState: { [weak self] in
                guard let self else { return .notEnabled }
                switch self.helperService.status {
                case .enabled: return self.helperUnreachable ? .unreachable : .enabled
                case .requiresApproval: return .requiresApproval
                default: return .notEnabled
                }
            },
            enableHelper: { [weak self] in self?.activateHelper() },
            repairHelper: { [weak self] in self?.repairHelperAction() },
            uninstallHelper: { [weak self] in self?.uninstallHelper() },
            isLoginItemEnabled: { SMAppService.mainApp.status == .enabled },
            setLoginItem: { [weak self] in self?.setLoginItem($0) },
            showLog: { [weak self] in self?.showLog() },
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
    }

    @objc private func openSettings() { showSettings(selecting: nil) }

    private func showSettings(selecting id: String?) {
        settingsWindow.show(selecting: id)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
