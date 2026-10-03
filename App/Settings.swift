import SwiftUI
import Security

/// Mots de passe et secret TOTP : Trousseau. Le reste : UserDefaults.
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

/// Le Trousseau, vu par ConfigStore.
struct KeychainSecrets: SecretStore {
    func get(_ account: String) -> String? { Keychain.get(account) }
    func set(_ value: String, account: String) { Keychain.set(value, account: account) }
}

extension ConfigStore {
    /// Le magasin de l'app : préférences de l'utilisateur et Trousseau.
    static let shared = ConfigStore(prefs: UserDefaults.standard, secrets: KeychainSecrets())
}

enum SettingsTab { case configurations, general }

struct SettingsView: View {
    var selecting: String?
    var general: GeneralActions?
    var onClose: () -> Void

    private let store: ConfigStore

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
        _totps = State(initialValue: Dictionary(uniqueKeysWithValues: list.map { ($0.id, store.totp(for: $0.id)) }))
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

    /// Liste des configurations et formulaire. Enregistrer / Annuler ne concernent que cet onglet.
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

    // MARK: Liste des configurations

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

    // MARK: Détail

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

    // MARK: Liaisons et actions

    private var name: Binding<String> {
        Binding(get: { current?.name ?? "" }, set: { v in if let i = index { configs[i].name = v } })
    }

    private func field(_ f: ConfigField) -> Binding<String> {
        Binding(get: { current?.value(f) ?? "" }, set: { v in if let i = index { configs[i].set(f, v) } })
    }

    /// Mot de passe ou secret TOTP de la configuration affichée.
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
