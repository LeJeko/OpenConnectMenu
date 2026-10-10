import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = HelperClient()
    private let helperService = SMAppService.daemon(plistName: Constants.helperPlist)

    private var status: VPNStatus?
    /// When `status` was received: the uptime shown in the menu goes on counting from it.
    private var statusReceivedAt = Date()
    private var liveMenuTimer: Timer?
    private var trust: TrustInfo?
    private var busy: String?
    private var lastError: String?
    /// The error is about reaching the helper: it goes away by itself as soon as the helper answers again.
    private var lastErrorIsLinkRelated = false
    private var timer: Timer?
    private lazy var settingsWindow = SettingsWindowController(general: makeGeneralActions())

    // Helper registered but unreachable (after a crash, an update, a failure of the system service…)
    private var unreachableCount = 0
    private var helperUnreachable = false
    private var repairAttempted = false
    private var repairing = false
    /// The helper has answered since the app started (or since the last repair). Until then the menu does not offer to
    /// connect: right after an update the helper often has to be repaired first, and a connection would just fail.
    private var helperResponded = false
    /// Consecutive failed polls before the helper is declared unreachable. Just 1 right after an update, where the
    /// helper is known to need a repair (brew removes its service); 5 (≈ 15 s) otherwise.
    private var unreachableThreshold = 5

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // A different build than the last launch: the app has just been updated.
        let lastBuild = UserDefaults.standard.string(forKey: "lastLaunchBuild")
        if let lastBuild, lastBuild != buildStamp { unreachableThreshold = 1 }
        UserDefaults.standard.set(buildStamp, forKey: "lastLaunchBuild")
        registerHelperIfNeeded()
        updateIcon()
        Task { await checkHelperVersion() }
        // In the .common modes, so that the state keeps being polled (and the open menu keeps updating) while a menu is open.
        let poll = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        refresh()
    }

    /// A menu-bar app has no menu bar of its own, and with no main menu the standard shortcuts (Cmd+V, Cmd+C, Cmd+A…)
    /// do nothing in the settings fields. This invisible Edit menu supplies them; the responder chain does the rest.
    private func installEditMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let edit = NSMenu(title: "Edit")
        for (title, action, key, mods) in [
            ("Undo", Selector(("undo:")), "z", NSEvent.ModifierFlags.command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ] as [(String, Selector, String, NSEvent.ModifierFlags)] {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            edit.addItem(i)
        }
        item.submenu = edit
        NSApp.mainMenu = main
    }

    private func setError(_ message: String, linkRelated: Bool) {
        lastError = message
        lastErrorIsLinkRelated = linkRelated
    }

    /// The "Approve openconnect?" dialog has already been shown by itself during this launch.
    private var approvalOffered = false

    private func registerHelperIfNeeded() {
        guard helperService.status == .notRegistered else { return }
        // A fresh registration is not an update of a helper that needs repairing: no immediate repair, which could undo
        // the approval the user is about to give.
        unreachableThreshold = 5
        do { try helperService.register() } catch { setError(L("Helper activation: %@", error.localizedDescription), linkRelated: true) }
        // First registration: macOS waits for the user to allow the helper. The pane is opened right away instead of
        // leaving a banner that is easy to miss.
        if helperService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// First run: once the helper answers and openconnect has never been approved, show the "Approve openconnect?" dialog
    /// by itself (once per launch), so that no menu click is needed. A binary that has CHANGED since it was approved
    /// (Homebrew update) is not offered automatically: that stays an explicit menu action.
    private func offerFirstApprovalIfNeeded() {
        guard !approvalOffered, busy == nil, !repairing, let t = trust,
              !t.trusted, t.code == "oc_not_approved", !t.openconnectPath.isEmpty else { return }
        approvalOffered = true
        approveTrust()
    }

    /// If an old helper is still running after an update, we restart it.
    private func checkHelperVersion() async {
        guard helperService.status == .enabled, let v = await client.version(), v != buildStamp else { return }
        client.quit()
    }

    // MARK: - State

    private func refresh() {
        updateIcon()
        guard helperService.status == .enabled else {
            unreachableCount = 0
            helperUnreachable = false
            helperResponded = false
            return
        }
        Task { @MainActor in
            guard let s = await client.status() else {
                noteUnreachable()
                updateIcon()
                return
            }
            setStatus(s)
            unreachableCount = 0
            unreachableThreshold = 5
            helperUnreachable = false
            helperResponded = true
            if lastErrorIsLinkRelated { lastError = nil; lastErrorIsLinkRelated = false }
            if let t = await client.trustInfo() { trust = t }
            updateIcon()
            offerFirstApprovalIfNeeded()
        }
    }

    /// The service is "enabled" as far as macOS is concerned but does not answer. We wait for a few polls (≈ 15 s) before
    /// concluding, except right after an update: the helper is started on demand and can be slow to answer (wake from sleep…).
    private func noteUnreachable() {
        guard busy == nil, !repairing else { return }
        unreachableCount += 1
        guard unreachableCount >= unreachableThreshold, !helperUnreachable else { return }
        unreachableThreshold = 5
        helperUnreachable = true
        let vpnWasUp = status?.connected == true
        status = nil
        // Automatic repair, only once, unless a VPN was up: the repair would
        // cut it. In that case the "Repair helper…" menu item remains available.
        if !repairAttempted && !vpnWasUp {
            repairAttempted = true
            Task { @MainActor in await repairHelper(automatic: true) }
        }
    }

    /// Re-registers the helper (unregister then register), without privileges: restarts the service
    /// with launchd and replaces an old process. The user's approval is kept.
    @MainActor
    private func repairHelper(automatic: Bool) async {
        guard !repairing else { return }
        repairing = true
        helperResponded = false
        busy = L("Repairing helper…")
        updateIcon()
        client.reset()
        try? await helperService.unregister()   // may fail if launchd already removed it: harmless
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
            setError(L("Helper repair: %@", failure), linkRelated: true)
            if !automatic { alert(L("Could not repair the helper"), failure) }
        }
        if !automatic && helperService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        updateIcon()
        refresh()
    }

    private func setStatus(_ s: VPNStatus) {
        status = s
        statusReceivedAt = Date()
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

    /// One line of the menu, described without any NSMenuItem: it can be compared with what is displayed.
    private struct MenuEntry {
        var title = ""
        var action: Selector?
        var configID: String?
        var isSeparator = false
        var targetsApp = false
    }

    /// Menu bar menus are rebuilt when they open, and then, while open, once a second: a change of state (helper
    /// starting, repaired, connected…) shows up without closing the menu, and the connection time keeps counting.
    func menuNeedsUpdate(_ menu: NSMenu) {
        apply(menuEntries(), to: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        liveMenuTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self, weak menu] _ in
            guard let self, let menu else { return }
            self.apply(self.menuEntries(), to: menu)
        }
        RunLoop.main.add(t, forMode: .common)
        liveMenuTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        liveMenuTimer?.invalidate()
        liveMenuTimer = nil
    }

    /// Same shape as what is displayed: only the titles that changed are updated, in place (no flicker, the highlighted
    /// line is kept). Otherwise the menu is rebuilt.
    private func apply(_ entries: [MenuEntry], to menu: NSMenu) {
        let items = menu.items
        let sameShape = items.count == entries.count && zip(items, entries).allSatisfy { item, e in
            item.isSeparatorItem == e.isSeparator && item.action == e.action
                && (item.representedObject as? String) == e.configID
        }
        if sameShape {
            for (item, e) in zip(items, entries) where !e.isSeparator && item.title != e.title { item.title = e.title }
            return
        }
        menu.removeAllItems()
        for e in entries {
            if e.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: e.title, action: e.action, keyEquivalent: "")
            item.target = e.targetsApp ? NSApp : self
            item.isEnabled = e.action != nil
            item.representedObject = e.configID
            menu.addItem(item)
        }
    }

    private func menuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        @discardableResult
        func add(_ title: String, _ action: Selector? = nil) -> Int {
            entries.append(MenuEntry(title: title, action: action))
            return entries.count - 1
        }
        func separator() { entries.append(MenuEntry(isSeparator: true)) }

        let helperState = helperService.status
        if let busy {
            add(busy)
        } else if !Homebrew.openConnectInstalled {
            // Detected on the app side, even before the helper is authorized.
            add(L("openconnect is not installed"))
            separator()
            add(L("Copy install command…"), #selector(showInstallCommand))
        } else if helperState == .requiresApproval {
            add(L("Helper needs approval in System Settings"))
            separator()
            add(L("Open Login Items…"), #selector(openLoginItems))
        } else if helperState != .enabled {
            add(L("Helper not enabled"))
            separator()
            add(L("Enable helper…"), #selector(activateHelper))
        } else if helperUnreachable {
            add(L("Helper not reachable"))
            separator()
            add(L("Repair helper…"), #selector(repairHelperAction))
        } else if !helperResponded {
            // Not connected to the helper yet (just launched, just updated or just repaired): nothing to offer.
            add(L("Starting the helper…"))
        } else if let trust, !trust.trusted {
            add(HelperText.localized(trust.code))
            separator()
            if trust.openconnectPath.isEmpty {
                // Nothing to approve: openconnect (or its vpnc-script) cannot be found.
                add(L("Copy install command…"), #selector(showInstallCommand))
            } else {
                add(L("Approve openconnect…"), #selector(approveTrust))
            }
        } else if let s = status, s.connected {
            // With several configurations, we show which one is connected.
            let store = ConfigStore.shared
            if store.configs().count > 1, let id = store.activeID, let name = store.config(id: id)?.name {
                add(L("VPN: connected to %@", name))
            } else {
                add(L("VPN: connected"))
            }
            add(L("Address: %@", s.tunnelIP))
            add(L("Since: %@", format(uptime: s.uptime + max(0, Date().timeIntervalSince(statusReceivedAt)))))
            separator()
            add(L("Disconnect"), #selector(disconnect))
        } else {
            add(L("VPN: disconnected"))
            separator()
            // One item per configuration; with a single one (or none: the settings then open), "Connect".
            let usable = ConfigStore.shared.menuConfigs()
            if usable.count > 1 {
                for c in usable {
                    entries[add(L("Connect to %@", c.name), #selector(connectConfig(_:)))].configID = c.id
                }
            } else {
                entries[add(L("Connect"), #selector(connectConfig(_:)))].configID = usable.first?.id
            }
        }

        if let lastError, busy == nil {
            separator()
            add("⚠️ " + lastError.split(separator: "\n").first.map(String.init)!)
        }

        separator()
        add(L("Settings…"), #selector(openSettings))
        separator()
        entries[add(L("Quit"), #selector(NSApplication.terminate(_:)))].targetsApp = true
        return entries
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
            showSettings(selecting: id)   // something is missing: we open the settings on this configuration
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
                setError(message, linkRelated: code == "helper_unreachable")
                alert(L("Connection failed"), message)
            }
            if let s = await client.status() { setStatus(s) }
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
                setError(message, linkRelated: code == "helper_unreachable")
                alert(L("Disconnection failed"), message)
            }
            if let s = await client.status() { setStatus(s) }
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

    /// What the settings' "General" tab reads and triggers: the former menu items.
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
