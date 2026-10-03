import Foundation

/// Champs d'une configuration qu'un profil de configuration macOS peut imposer.
/// La valeur brute est le nom de la clé dans le profil (et dans UserDefaults pour les clés « plates » historiques).
enum ConfigField: String, CaseIterable {
    case server
    case vpnProtocol = "protocol"
    case authgroup
    case useragent
    case username
}

/// Une configuration VPN. Le mot de passe et le secret TOTP n'en font pas partie : ils vivent dans le Trousseau,
/// sous un compte propre à chaque configuration (voir ConfigStore.account).
struct VPNConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var server = ""
    var vpnProtocol = Constants.defaultProtocol
    var authgroup = ""
    var useragent = ""
    var username = ""

    // Non enregistrés : déterminés à chaque lecture.
    /// Configuration apportée par un profil de configuration (lecture seule, non supprimable).
    var managed = false
    /// Champs imposés par un profil : affichés grisés, jamais réécrits.
    var locked: Set<ConfigField> = []

    enum CodingKeys: String, CodingKey { case id, name, server, vpnProtocol, authgroup, useragent, username }

    func isLocked(_ f: ConfigField) -> Bool { locked.contains(f) }

    /// Une configuration sans serveur n'est pas proposée dans le menu.
    var isUsable: Bool { !server.isEmpty }

    func value(_ f: ConfigField) -> String {
        switch f {
        case .server: return server
        case .vpnProtocol: return vpnProtocol
        case .authgroup: return authgroup
        case .useragent: return useragent
        case .username: return username
        }
    }

    mutating func set(_ f: ConfigField, _ v: String) {
        switch f {
        case .server: server = v
        case .vpnProtocol: vpnProtocol = v
        case .authgroup: authgroup = v
        case .useragent: useragent = v
        case .username: username = v
        }
    }
}

/// Préférences : UserDefaults en vrai, une fausse implémentation dans les tests.
protocol PreferenceSource: AnyObject {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func array(forKey key: String) -> [Any]?
    func dictionary(forKey key: String) -> [String: Any]?
    /// Vrai si la valeur est imposée par un profil de configuration.
    func isForced(_ key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceSource {
    func isForced(_ key: String) -> Bool { objectIsForced(forKey: key) }
}

/// Mots de passe et secrets TOTP : le Trousseau en vrai, une fausse implémentation dans les tests.
protocol SecretStore {
    func get(_ account: String) -> String?
    /// Une valeur vide supprime l'élément.
    func set(_ value: String, account: String)
}
