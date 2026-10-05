import SwiftUI
import AppKit
import Security

/// Passwords and TOTP secret: Keychain. Everything else: UserDefaults.
enum Keychain {
    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Constants.appBundleID,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Constants.appBundleID,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The Keychain, as seen by ConfigStore.
struct KeychainSecrets: SecretStore {
    func get(_ account: String) -> String? { Keychain.get(account) }
    func set(_ value: String, account: String) { Keychain.set(value, account: account) }
}

extension ConfigStore {
    /// The app's store: user preferences and Keychain.
    static let shared = ConfigStore(prefs: UserDefaults.standard, secrets: KeychainSecrets())
}

enum SettingsTab { case configurations, general }

struct SettingsView: View {
    var selecting: String?
    var general: GeneralActions?
    var onClose: () -> Void

    private let store: ConfigStore
    /// TOTP secrets as stored when the window opened: the verification code is only shown for a secret that differs.
    private let initialTOTPs: [String: String]

    @State private var configs: [VPNConfig]
    @State private var selection: String
    @State private var passwords: [String: String]
    @State private var totps: [String: String]
    @State private var tab: SettingsTab

    init(store: ConfigStore = .shared, selecting: String? = nil, general: GeneralActions? = nil,
         tab: SettingsTab = .configurations, onClose: @escaping () -> Void) {
        self.store = store
        self.selecting = selecting
        self.general = general
        self._tab = State(initialValue: tab)
        self.onClose = onClose
        let list = store.configs()
        _configs = State(initialValue: list)
        _selection = State(initialValue: list.first(where: { $0.id == selecting })?.id ?? list.first?.id ?? "")
        _passwords = State(initialValue: Dictionary(uniqueKeysWithValues: list.map { ($0.id, store.password(for: $0.id)) }))
        let stored = Dictionary(uniqueKeysWithValues: list.map { ($0.id, store.totp(for: $0.id)) })
        _totps = State(initialValue: stored)
        initialTOTPs = stored
    }

    private var index: Int? { configs.firstIndex { $0.id == selection } }
    private var current: VPNConfig? { index.map { configs[$0] } }
    private var anyLocked: Bool { configs.contains { $0.managed || !$0.locked.isEmpty } }

    var body: some View {
        Group {
            if let general {
                TabView(selection: $tab) {
                    configurationsTab
                        .tabItem { Text("Configurations") }
                        .tag(SettingsTab.configurations)
                    GeneralSettingsView(actions: general)
                        .tabItem { Text("General") }
                        .tag(SettingsTab.general)
                }
            } else {
                configurationsTab
            }
        }
        .frame(width: 720, height: general == nil ? 560 : 610)
    }

    /// Configuration list and form. Save / Cancel only concern this tab.
    private var configurationsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
            Divider()
            HStack {
                if anyLocked {
                    Label("Some settings are imposed by a configuration profile and cannot be changed.", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    // MARK: Configuration list

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(configs) { c in
                    HStack {
                        Text(verbatim: c.name)
                        Spacer()
                        if c.managed {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help(L("Managed by a configuration profile"))
                        }
                    }
                    .tag(c.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 4) {
                Button(action: add) { Image(systemName: "plus") }
                    .help(L("Add a configuration"))
                Button(action: remove) { Image(systemName: "minus") }
                    .help(L("Remove the configuration"))
                    .disabled(current == nil || current?.managed == true)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(width: 210)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let c = current {
            Form {
                Section("Configuration") {
                    TextField("Name", text: name).disabled(c.managed)
                }
                Section("Server") {
                    TextField("Address", text: field(.server), prompt: Text(verbatim: "https://vpn.example.com"))
                        .disabled(c.isLocked(.server))
                    Picker("Protocol", selection: field(.vpnProtocol)) {
                        ForEach(Constants.protocols, id: \.id) { Text(verbatim: $0.label).tag($0.id) }
                    }
                    .disabled(c.isLocked(.vpnProtocol))
                    TextField("Authentication group", text: field(.authgroup), prompt: Text("Optional"))
                        .disabled(c.isLocked(.authgroup))
                    TextField("User-Agent", text: field(.useragent), prompt: Text("Optional"))
                        .disabled(c.isLocked(.useragent))
                }
                Section {
                    TextField("Username", text: field(.username))
                        .disabled(c.isLocked(.username))
                    SecureField("Password", text: secret($passwords))
                    SecureField("TOTP secret", text: secret($totps))
                    // Shown only while a new secret is being entered (to complete the identity provider's verification
                    // step); once saved, the settings never show codes again.
                    if let entered = totps[c.id], !entered.isEmpty, entered != initialTOTPs[c.id] {
                        VerificationCodeRow(secret: entered)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("The TOTP secret accepts the bare Base32 key or the full otpauth:// URL. Password and secret are stored in your Keychain.")
                }
            }
            .formStyle(.grouped)
        } else {
            VStack {
                Spacer()
                Text("No configuration. Click + to add one.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Bindings and actions

    private var name: Binding<String> {
        Binding(get: { current?.name ?? "" }, set: { v in if let i = index { configs[i].name = v } })
    }

    private func field(_ f: ConfigField) -> Binding<String> {
        Binding(get: { current?.value(f) ?? "" }, set: { v in if let i = index { configs[i].set(f, v) } })
    }

    /// Password or TOTP secret of the configuration being shown.
    private func secret(_ values: Binding<[String: String]>) -> Binding<String> {
        Binding(get: { values.wrappedValue[selection] ?? "" }, set: { values.wrappedValue[selection] = $0 })
    }

    private func add() {
        let c = ConfigStore.newUserConfig()
        configs.append(c)
        passwords[c.id] = ""
        totps[c.id] = ""
        selection = c.id
    }

    private func remove() {
        guard let i = index, !configs[i].managed else { return }
        let id = configs[i].id
        configs.remove(at: i)
        passwords[id] = nil
        totps[id] = nil
        selection = configs.first?.id ?? ""
    }

    private func save() {
        store.save(configs)
        for c in configs {
            store.setPassword(passwords[c.id] ?? "", for: c.id)
            store.setTOTP(totps[c.id] ?? "", for: c.id)
        }
        onClose()
    }
}

/// The live verification code of a secret being entered, with the seconds left and a Copy button.
struct VerificationCodeRow: View {
    let secret: String

    var body: some View {
        if TOTP.code(secret: secret) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = TOTP.code(secret: secret, at: context.date) ?? ""
                LabeledContent("Verification code") {
                    HStack(spacing: 10) {
                        Text(verbatim: Self.grouped(code))
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                        CountdownRing(remaining: TOTP.secondsRemaining(at: context.date))
                        Button("Copy") { Self.copy(code) }
                    }
                }
            }
        } else {
            LabeledContent("Verification code") { Text("Invalid secret").foregroundStyle(.secondary) }
        }
    }

    /// "123456" → "123 456".
    private static func grouped(_ code: String) -> String {
        let half = code.count / 2
        return code.prefix(half) + " " + code.dropFirst(half)
    }

    /// The pasteboard entry is marked "concealed" so that clipboard managers do not keep it.
    private static func copy(_ code: String) {
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(code, forType: .string)
        pasteboard.setString("", forType: concealed)
    }
}

/// The time left before the code changes: a ring that empties, with the seconds inside; orange for the last 5 seconds.
struct CountdownRing: View {
    let remaining: Int

    var body: some View {
        let low = remaining <= 5
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(remaining) / CGFloat(TOTP.period))
                .stroke(low ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(remaining)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(low ? Color.orange : Color.secondary)
        }
        .frame(width: 26, height: 26)
        .help(L("%d s", remaining))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%d s", remaining))
    }
}
