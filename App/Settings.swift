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

enum SettingsStore {
    private static let d = UserDefaults.standard

    /// Réglage imposé par un profil de configuration macOS (installé à la main ou par MDM) :
    /// UserDefaults renvoie alors la valeur du profil, et l'utilisateur ne peut pas la changer.
    static func isManaged(_ key: String) -> Bool { d.objectIsForced(forKey: key) }

    static var server: String {
        get { d.string(forKey: "server") ?? "" }
        set { d.set(newValue, forKey: "server") }
    }
    /// Protocole d'openconnect. Une valeur inconnue (profil mal écrit…) retombe sur AnyConnect.
    static var vpnProtocol: String {
        get {
            let v = d.string(forKey: "protocol") ?? Constants.defaultProtocol
            return Constants.protocols.contains(where: { $0.id == v }) ? v : Constants.defaultProtocol
        }
        set { d.set(newValue, forKey: "protocol") }
    }
    static var authgroup: String {
        get { d.string(forKey: "authgroup") ?? "" }
        set { d.set(newValue, forKey: "authgroup") }
    }
    static var useragent: String {
        get { d.string(forKey: "useragent") ?? "" }
        set { d.set(newValue, forKey: "useragent") }
    }
    static var username: String {
        get { d.string(forKey: "username") ?? "" }
        set { d.set(newValue, forKey: "username") }
    }
    static var password: String {
        get { Keychain.get("password") ?? "" }
        set { Keychain.set(newValue, account: "password") }
    }
    static var totpSecret: String {
        get { Keychain.get("totp") ?? "" }
        set { Keychain.set(normalizeTOTP(newValue), account: "totp") }
    }

    /// Accepte une clé nue, une clé « base32:… » ou l'URL otpauth:// complète.
    static func normalizeTOTP(_ input: String) -> String {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("otpauth://"),
           let items = URLComponents(string: t)?.queryItems,
           let secret = items.first(where: { $0.name == "secret" })?.value {
            t = secret
        }
        t = t.replacingOccurrences(of: "base32:", with: "", options: .caseInsensitive)
        return t.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
    }

    static func makeRequest() -> ConnectRequest? {
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty, !totpSecret.isEmpty else { return nil }
        return ConnectRequest(server: server, vpnProtocol: vpnProtocol, authgroup: authgroup, useragent: useragent,
                              username: username, password: password, totpSecret: totpSecret)
    }
}

struct SettingsView: View {
    var onClose: () -> Void

    @State private var server = SettingsStore.server
    @State private var vpnProtocol = SettingsStore.vpnProtocol
    @State private var authgroup = SettingsStore.authgroup
    @State private var useragent = SettingsStore.useragent
    @State private var username = SettingsStore.username
    @State private var password = SettingsStore.password
    @State private var totp = SettingsStore.totpSecret

    private let managedKeys = ["server", "protocol", "authgroup", "useragent", "username"]
    private var anyManaged: Bool { managedKeys.contains(where: SettingsStore.isManaged) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Section("Server") {
                    TextField("Address", text: $server, prompt: Text(verbatim: "https://vpn.example.com"))
                        .disabled(SettingsStore.isManaged("server"))
                    Picker("Protocol", selection: $vpnProtocol) {
                        ForEach(Constants.protocols, id: \.id) { Text(verbatim: $0.label).tag($0.id) }
                    }
                    .disabled(SettingsStore.isManaged("protocol"))
                    TextField("Authentication group", text: $authgroup, prompt: Text("Optional"))
                        .disabled(SettingsStore.isManaged("authgroup"))
                    TextField("User-Agent", text: $useragent, prompt: Text("Optional"))
                        .disabled(SettingsStore.isManaged("useragent"))
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .disabled(SettingsStore.isManaged("username"))
                    SecureField("Password", text: $password)
                    SecureField("TOTP secret", text: $totp)
                }
            }
            .formStyle(.grouped)

            Text("The TOTP secret accepts the bare Base32 key or the full otpauth:// URL. Password and secret are stored in your Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if anyManaged {
                Label("Some settings are imposed by a configuration profile and cannot be changed.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Les réglages imposés par un profil ne sont jamais réécrits.
                    if !SettingsStore.isManaged("server") { SettingsStore.server = server.trimmingCharacters(in: .whitespaces) }
                    if !SettingsStore.isManaged("protocol") { SettingsStore.vpnProtocol = vpnProtocol }
                    if !SettingsStore.isManaged("authgroup") { SettingsStore.authgroup = authgroup.trimmingCharacters(in: .whitespaces) }
                    if !SettingsStore.isManaged("useragent") { SettingsStore.useragent = useragent.trimmingCharacters(in: .whitespaces) }
                    if !SettingsStore.isManaged("username") { SettingsStore.username = username.trimmingCharacters(in: .whitespaces) }
                    SettingsStore.password = password
                    SettingsStore.totpSecret = totp
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 460, height: anyManaged ? 510 : 470)
    }
}
