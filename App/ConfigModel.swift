import Foundation

/// Fields of a configuration that a macOS configuration profile can enforce.
/// The raw value is the key name in the profile (and in UserDefaults for the historical "flat" keys).
enum ConfigField: String, CaseIterable {
    case server
    case vpnProtocol = "protocol"
    case authgroup
    case useragent
    case username
}

/// A VPN configuration. The password and the TOTP secret are not part of it: they live in the Keychain,
/// under an account specific to each configuration (see ConfigStore.account).
struct VPNConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var server = ""
    var vpnProtocol = Constants.defaultProtocol
    var authgroup = ""
    var useragent = ""
    var username = ""

    // Not stored: determined on every read.
    /// Configuration supplied by a configuration profile (read-only, cannot be deleted).
    var managed = false
    /// Fields enforced by a profile: shown greyed out, never rewritten.
    var locked: Set<ConfigField> = []

    enum CodingKeys: String, CodingKey { case id, name, server, vpnProtocol, authgroup, useragent, username }

    func isLocked(_ f: ConfigField) -> Bool { locked.contains(f) }

    /// A configuration without a server is not offered in the menu.
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

/// Preferences: UserDefaults for real, a fake implementation in the tests.
protocol PreferenceSource: AnyObject {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func array(forKey key: String) -> [Any]?
    func dictionary(forKey key: String) -> [String: Any]?
    /// True if the value is enforced by a configuration profile.
    func isForced(_ key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceSource {
    func isForced(_ key: String) -> Bool { objectIsForced(forKey: key) }
}

/// Passwords and TOTP secrets: the Keychain for real, a fake implementation in the tests.
protocol SecretStore {
    func get(_ account: String) -> String?
    /// An empty value deletes the item.
    func set(_ value: String, account: String)
}
