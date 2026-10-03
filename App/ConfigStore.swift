import Foundation

/// Les configurations VPN : celles de l'utilisateur (enregistrées) et celles d'un profil de configuration macOS
/// (lues, jamais enregistrées). Toute la logique est ici, sans interface : elle se teste seule (build.sh test).
///
/// Stockage :
///  - `configurations.user` (UserDefaults, JSON) : les configurations de l'utilisateur ;
///  - `configurations` (domaine géré, imposé par un profil) : tableau de dictionnaires {name, server, protocol,
///    authgroup, useragent, username}. Les champs présents et non vides sont imposés, les autres restent libres ;
///  - `managedOverrides` : valeurs saisies par l'utilisateur pour les champs libres d'une configuration de profil ;
///  - Trousseau : comptes `password.<id>` et `totp.<id>`. La configuration « default » (celle d'avant la
///    version 2) garde les comptes `password` et `totp` : aucune ressaisie après la mise à jour.
///  - les clés « plates » historiques (server, protocol…) imposées par un ancien profil restent une surcouche
///    sur la configuration « default ».
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

    // MARK: - Lecture

    /// Toutes les configurations : celles d'un profil d'abord, puis celles de l'utilisateur.
    func configs() -> [VPNConfig] { managedConfigs() + userConfigs() }

    func config(id: String) -> VPNConfig? { configs().first { $0.id == id } }

    /// Celles qu'on peut connecter (serveur renseigné).
    func menuConfigs() -> [VPNConfig] { configs().filter(\.isUsable) }

    /// Configuration connectée en dernier par l'app (pour afficher son nom pendant la connexion).
    var activeID: String? {
        get { prefs.string(forKey: Self.activeKey) }
        set { prefs.set(newValue, forKey: Self.activeKey) }
    }

    // MARK: - Configurations de l'utilisateur et migration

    private func loadStoredUser() -> [VPNConfig]? {
        guard let data = prefs.data(forKey: Self.userKey) else { return nil }
        // Données illisibles : on n'écrase rien, on repart d'une configuration vide.
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
            // Premier lancement depuis une version 1.x (ou installation neuve) : la configuration unique d'avant
            // devient « default », avec ses secrets (mêmes comptes de Trousseau). Les anciennes clés sont gardées.
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

    /// Les clés plates imposées par un ancien profil (1.x) s'appliquent à « default », comme avant.
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

    // MARK: - Configurations d'un profil

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

    // MARK: - Écriture

    /// Enregistre l'état édité dans les réglages : la liste des configurations de l'utilisateur, et pour celles d'un
    /// profil les seuls champs libres. Les éléments de Trousseau des configurations supprimées sont effacés.
    /// Un champ imposé n'est jamais réécrit (la valeur du profil ne se retrouve pas dans les réglages de l'utilisateur).
    func save(_ edited: [VPNConfig]) {
        let previous = loadStoredUser() ?? []
        var overrides = prefs.dictionary(forKey: Self.overridesKey) as? [String: [String: String]] ?? [:]
        var user: [VPNConfig] = []

        for var c in edited {
            if c.managed {
                var o: [String: String] = [:]
                for f in ConfigField.allCases where !c.isLocked(f) {
                    let v = c.value(f).trimmingCharacters(in: .whitespaces)
                    // Le protocole par défaut n'est pas un choix de l'utilisateur : on ne l'enregistre pas.
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

    /// Une nouvelle configuration vide pour l'utilisateur.
    static func newUserConfig() -> VPNConfig {
        VPNConfig(id: UUID().uuidString, name: NSLocalizedString("New configuration", comment: ""))
    }

    // MARK: - Secrets

    /// « default » garde les comptes d'avant la version 2 ; les autres ont un compte par configuration.
    static func account(_ kind: String, id: String) -> String { id == defaultID ? kind : "\(kind).\(id)" }

    func password(for id: String) -> String { secrets.get(Self.account("password", id: id)) ?? "" }
    func totp(for id: String) -> String { secrets.get(Self.account("totp", id: id)) ?? "" }
    func setPassword(_ v: String, for id: String) { secrets.set(v, account: Self.account("password", id: id)) }
    func setTOTP(_ v: String, for id: String) { secrets.set(Self.normalizeTOTP(v), account: Self.account("totp", id: id)) }

    func purgeSecrets(for id: String) {
        secrets.set("", account: Self.account("password", id: id))
        secrets.set("", account: Self.account("totp", id: id))
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

    // MARK: - Demande de connexion

    /// Nil s'il manque quelque chose (serveur, identifiant, mot de passe ou secret TOTP).
    func request(for id: String) -> ConnectRequest? {
        guard let c = config(id: id), c.isUsable, !c.username.isEmpty else { return nil }
        let pw = password(for: id), totp = totp(for: id)
        guard !pw.isEmpty, !totp.isEmpty else { return nil }
        return ConnectRequest(server: c.server, vpnProtocol: c.vpnProtocol, authgroup: c.authgroup, useragent: c.useragent,
                              username: c.username, password: pw, totpSecret: totp)
    }

    // MARK: - Outils

    /// Protocole connu, sinon AnyConnect (valeur inconnue : profil mal écrit, ancienne version…).
    static func validProtocol(_ v: String?) -> String {
        guard let v, Constants.protocols.contains(where: { $0.id == v }) else { return Constants.defaultProtocol }
        return v
    }

    /// Texte sans caractère de contrôle (il finit dans des menus et dans la configuration d'openconnect).
    static func isPlain(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Nom affichable : sans caractère de contrôle, espaces réduits, 60 caractères au plus ; nil s'il est vide.
    static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let noControls = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let collapsed = noControls.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxNameLength))
    }

    /// « Mon VPN (travail) » → « mon-vpn-travail ».
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
