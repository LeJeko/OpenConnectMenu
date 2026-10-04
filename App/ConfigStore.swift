import Foundation

/// The VPN configurations: the user's own (stored) and those from a macOS configuration profile
/// (read, never stored). All the logic is here, without any UI: it can be tested on its own (build.sh test).
///
/// Storage:
///  - `configurations.user` (UserDefaults, JSON): the user's configurations;
///  - `configurations` (managed domain, enforced by a profile): array of dictionaries {name, server, protocol,
///    authgroup, useragent, username}. Fields that are present and non-empty are enforced, the others stay free;
///  - `managedOverrides`: values entered by the user for the free fields of a profile configuration;
///  - Keychain: accounts `password.<id>` and `totp.<id>`. The "default" configuration (the one from before
///    version 2) keeps the `password` and `totp` accounts: nothing to re-enter after the update.
///  - the historical "flat" keys (server, protocol…) enforced by an old profile remain an overlay
///    on the "default" configuration.
final class ConfigStore {
    static let defaultID = "default"
    static let userKey = "configurations.user"
    static let managedKey = "configurations"
    static let overridesKey = "managedOverrides"
    static let activeKey = "activeConfigID"
    static let maxNameLength = 60

    private let prefs: PreferenceSource
    private let secrets: SecretStore

    init(prefs: PreferenceSource, secrets: SecretStore) {
        self.prefs = prefs
        self.secrets = secrets
    }

    // MARK: - Reading

    /// All configurations: those from a profile first, then the user's.
    func configs() -> [VPNConfig] { managedConfigs() + userConfigs() }

    func config(id: String) -> VPNConfig? { configs().first { $0.id == id } }

    /// Those that can be connected (server filled in).
    func menuConfigs() -> [VPNConfig] { configs().filter(\.isUsable) }

    /// Configuration the app connected last (to show its name while connected).
    var activeID: String? {
        get { prefs.string(forKey: Self.activeKey) }
        set { prefs.set(newValue, forKey: Self.activeKey) }
    }

    // MARK: - User configurations and migration

    private func loadStoredUser() -> [VPNConfig]? {
        guard let data = prefs.data(forKey: Self.userKey) else { return nil }
        // Unreadable data: we overwrite nothing and start again from an empty configuration.
        return (try? JSONDecoder().decode([VPNConfig].self, from: data)) ?? [Self.emptyDefault()]
    }

    private static func emptyDefault() -> VPNConfig {
        VPNConfig(id: defaultID, name: NSLocalizedString("Default", comment: ""))
    }

    private func persistUser(_ list: [VPNConfig]) {
        if let data = try? JSONEncoder().encode(list) { prefs.set(data, forKey: Self.userKey) }
    }

    private func userConfigs() -> [VPNConfig] {
        var list: [VPNConfig]
        if let stored = loadStoredUser() {
            list = stored
        } else {
            // First launch since a 1.x version (or a fresh install): the former single configuration
            // becomes "default", with its secrets (same Keychain accounts). The old keys are kept.
            var d = Self.emptyDefault()
            d.server = prefs.string(forKey: ConfigField.server.rawValue) ?? ""
            d.vpnProtocol = Self.validProtocol(prefs.string(forKey: ConfigField.vpnProtocol.rawValue))
            d.authgroup = prefs.string(forKey: ConfigField.authgroup.rawValue) ?? ""
            d.useragent = prefs.string(forKey: ConfigField.useragent.rawValue) ?? ""
            d.username = prefs.string(forKey: ConfigField.username.rawValue) ?? ""
            list = [d]
            persistUser(list)
        }
        return list.map { Self.legacyOverlay($0, prefs: prefs) }
    }

    /// The flat keys enforced by an old (1.x) profile apply to "default", as before.
    private static func legacyOverlay(_ config: VPNConfig, prefs: PreferenceSource) -> VPNConfig {
        var c = config
        c.vpnProtocol = validProtocol(c.vpnProtocol)
        guard c.id == defaultID else { return c }
        for f in ConfigField.allCases where prefs.isForced(f.rawValue) {
            guard let v = prefs.string(forKey: f.rawValue) else { continue }
            c.set(f, f == .vpnProtocol ? validProtocol(v) : v)
            c.locked.insert(f)
        }
        return c
    }

    // MARK: - Profile configurations

    private func managedConfigs() -> [VPNConfig] {
        guard prefs.isForced(Self.managedKey), let raw = prefs.array(forKey: Self.managedKey) else { return [] }
        let overrides = prefs.dictionary(forKey: Self.overridesKey) as? [String: [String: String]] ?? [:]
        var used = Set<String>()
        var out: [VPNConfig] = []
        for item in raw {
            guard let dict = item as? [String: Any], let name = Self.cleanName(dict["name"] as? String) else { continue }
            var id = "managed:" + Self.slug(name)
            var n = 2
            while used.contains(id) { id = "managed:\(Self.slug(name))-\(n)"; n += 1 }
            used.insert(id)

            var c = VPNConfig(id: id, name: name)
            c.managed = true
            for f in ConfigField.allCases {
                let imposed = (dict[f.rawValue] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let free = overrides[id]?[f.rawValue]
                if f == .vpnProtocol {
                    if Constants.protocols.contains(where: { $0.id == imposed }) { c.vpnProtocol = imposed; c.locked.insert(f) }
                    else { c.vpnProtocol = Self.validProtocol(free) }
                } else if !imposed.isEmpty && Self.isPlain(imposed) {
                    c.set(f, imposed)
                    c.locked.insert(f)
                } else {
                    c.set(f, free ?? "")
                }
            }
            out.append(c)
        }
        return out
    }

    // MARK: - Writing

    /// Stores the state edited in the settings: the list of the user's configurations and, for those from a
    /// profile, only the free fields. The Keychain items of deleted configurations are erased.
    /// An enforced field is never rewritten (the profile's value does not end up in the user's settings).
    func save(_ edited: [VPNConfig]) {
        let previous = loadStoredUser() ?? []
        var overrides = prefs.dictionary(forKey: Self.overridesKey) as? [String: [String: String]] ?? [:]
        var user: [VPNConfig] = []

        for var c in edited {
            if c.managed {
                var o: [String: String] = [:]
                for f in ConfigField.allCases where !c.isLocked(f) {
                    let v = c.value(f).trimmingCharacters(in: .whitespaces)
                    // The default protocol is not a user choice: we do not store it.
                    if !v.isEmpty && !(f == .vpnProtocol && v == Constants.defaultProtocol) { o[f.rawValue] = v }
                }
                overrides[c.id] = o
                continue
            }
            let before = previous.first { $0.id == c.id }
            for f in ConfigField.allCases {
                if c.isLocked(f) { c.set(f, before?.value(f) ?? "") }
                else { c.set(f, c.value(f).trimmingCharacters(in: .whitespaces)) }
            }
            c.name = Self.cleanName(c.name) ?? NSLocalizedString("New configuration", comment: "")
            c.managed = false
            c.locked = []
            user.append(c)
        }

        let keptIDs = Set(user.map(\.id))
        for gone in previous where !keptIDs.contains(gone.id) { purgeSecrets(for: gone.id) }
        persistUser(user)
        prefs.set(overrides, forKey: Self.overridesKey)
    }

    /// A new, empty configuration for the user.
    static func newUserConfig() -> VPNConfig {
        VPNConfig(id: UUID().uuidString, name: NSLocalizedString("New configuration", comment: ""))
    }

    // MARK: - Secrets

    /// "default" keeps the accounts from before version 2; the others have one account per configuration.
    static func account(_ kind: String, id: String) -> String { id == defaultID ? kind : "\(kind).\(id)" }

    func password(for id: String) -> String { secrets.get(Self.account("password", id: id)) ?? "" }
    func totp(for id: String) -> String { secrets.get(Self.account("totp", id: id)) ?? "" }
    func setPassword(_ v: String, for id: String) { secrets.set(v, account: Self.account("password", id: id)) }
    func setTOTP(_ v: String, for id: String) { secrets.set(Self.normalizeTOTP(v), account: Self.account("totp", id: id)) }

    func purgeSecrets(for id: String) {
        secrets.set("", account: Self.account("password", id: id))
        secrets.set("", account: Self.account("totp", id: id))
    }

    /// Accepts a bare key, a "base32:…" key or the full otpauth:// URL.
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

    // MARK: - Connection request

    /// Nil if anything is missing (server, username, password or TOTP secret).
    func request(for id: String) -> ConnectRequest? {
        guard let c = config(id: id), c.isUsable, !c.username.isEmpty else { return nil }
        let pw = password(for: id), totp = totp(for: id)
        guard !pw.isEmpty, !totp.isEmpty else { return nil }
        return ConnectRequest(server: c.server, vpnProtocol: c.vpnProtocol, authgroup: c.authgroup, useragent: c.useragent,
                              username: c.username, password: pw, totpSecret: totp)
    }

    // MARK: - Helpers

    /// A known protocol, otherwise AnyConnect (unknown value: badly written profile, old version…).
    static func validProtocol(_ v: String?) -> String {
        guard let v, Constants.protocols.contains(where: { $0.id == v }) else { return Constants.defaultProtocol }
        return v
    }

    /// Text without control characters (it ends up in menus and in openconnect's configuration).
    static func isPlain(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Displayable name: no control characters, whitespace collapsed, 60 characters at most; nil if empty.
    static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let noControls = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let collapsed = noControls.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxNameLength))
    }

    /// "My VPN (work)" → "my-vpn-work".
    static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "config" : out
    }
}
