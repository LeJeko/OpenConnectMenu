import Foundation

// Tests of ConfigStore, with no UI and no real Keychain: ./build.sh test

/// Simulated preferences. `managed` imitates a configuration profile's managed domain: these values are read first,
/// reported as "forced", and a write to the same key does not change them.
final class FakePrefs: PreferenceSource {
    var store: [String: Any] = [:]
    var managed: [String: Any] = [:]
    private func value(_ k: String) -> Any? { managed[k] ?? store[k] }
    func string(forKey k: String) -> String? { value(k) as? String }
    func data(forKey k: String) -> Data? { value(k) as? Data }
    func array(forKey k: String) -> [Any]? { value(k) as? [Any] }
    func dictionary(forKey k: String) -> [String: Any]? { value(k) as? [String: Any] }
    func isForced(_ k: String) -> Bool { managed[k] != nil }
    func set(_ v: Any?, forKey k: String) { store[k] = v }
}

final class FakeSecrets: SecretStore {
    var items: [String: String] = [:]
    func get(_ account: String) -> String? { items[account] }
    func set(_ value: String, account: String) { if value.isEmpty { items[account] = nil } else { items[account] = value } }
}

var failures = 0
var count = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    count += 1
    if !ok { failures += 1 }
    print(ok ? "OK   " : "FAIL ", name, ok ? "" : "\n       \(detail())")
}

func make() -> (ConfigStore, FakePrefs, FakeSecrets) {
    let p = FakePrefs(), s = FakeSecrets()
    return (ConfigStore(prefs: p, secrets: s), p, s)
}

func profile(_ items: [Any]) -> [Any] { items }

@main
struct ConfigStoreTests {
    static func main() {
        // ---- fresh install and migration
        do {
            let (st, p, _) = make()
            let c = st.configs()
            check("fresh: a single empty 'default' configuration", c.count == 1 && c[0].id == "default" && c[0].server.isEmpty && !c[0].managed)
            check("fresh: nothing to offer in the menu", st.menuConfigs().isEmpty)
            check("fresh: the migration is stored", p.store[ConfigStore.userKey] is Data)
        }
        do {
            let (st, p, s) = make()
            p.store["server"] = "https://vpn.example.com"; p.store["protocol"] = "gp"; p.store["authgroup"] = "G"
            p.store["useragent"] = "UA"; p.store["username"] = "alice"
            s.items["password"] = "pw"; s.items["totp"] = "JBSWY3DPEHPK3PXP"
            let d = st.configs()[0]
            check("migration: the flat keys become 'default'", d.id == "default" && d.server == "https://vpn.example.com" && d.vpnProtocol == "gp" && d.authgroup == "G" && d.useragent == "UA" && d.username == "alice", "\(d)")
            check("migration: secrets kept under the old accounts", st.password(for: "default") == "pw" && st.totp(for: "default") == "JBSWY3DPEHPK3PXP")
            check("migration: connecting works without re-entering anything", st.request(for: "default")?.password == "pw")
            p.store["server"] = "https://autre.example.com"
            check("migration: runs only once", st.configs()[0].server == "https://vpn.example.com")
            check("migration: the flat keys are not deleted", p.store["server"] != nil && p.store["username"] != nil)
        }
        do {
            let (st, p, _) = make()
            p.store[ConfigStore.userKey] = Data("pas du json".utf8)
            let c = st.configs()
            check("unreadable data: an empty configuration, nothing overwritten", c.count == 1 && c[0].id == "default" && (p.store[ConfigStore.userKey] as? Data) == Data("pas du json".utf8))
        }

        // ---- overlay of the old enforced flat keys
        do {
            let (st, p, _) = make()
            p.store["server"] = "https://mon.vpn"; p.store["username"] = "alice"
            _ = st.configs()
            p.managed["server"] = "https://impose.example.org"; p.managed["protocol"] = "pulse"
            let d = st.configs()[0]
            check("old profile: enforced values applied to 'default'", d.server == "https://impose.example.org" && d.vpnProtocol == "pulse")
            check("old profile: enforced fields locked, the others free", d.isLocked(.server) && d.isLocked(.vpnProtocol) && !d.isLocked(.username) && d.username == "alice")
            var e = d; e.username = "bob"; e.server = "https://modifie.example"
            st.save([e])
            p.managed = [:]
            let after = st.configs()[0]
            check("old profile: the enforced value is never written to the settings", after.server == "https://mon.vpn" && after.username == "bob", "\(after)")
        }

        // ---- profile configurations
        let two: [[String: Any]] = [
            ["name": "Travail", "server": "https://vpn.travail.example", "protocol": "gp", "authgroup": "Staff", "useragent": "PAN"],
            ["name": "Labo", "server": "https://vpn.labo.example", "username": "labuser"],
        ]
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            let c = st.configs()
            check("profile: its two configurations first, then 'default'", c.map(\.id) == ["managed:travail", "managed:labo", "default"], "\(c.map(\.id))")
            check("profile: read-only", c[0].managed && c[1].managed && !c[2].managed)
            check("profile: fields that are present are locked", c[0].isLocked(.server) && c[0].isLocked(.vpnProtocol) && c[0].isLocked(.authgroup) && c[0].isLocked(.useragent) && !c[0].isLocked(.username))
            check("profile: values read", c[0].vpnProtocol == "gp" && c[0].authgroup == "Staff" && c[1].username == "labuser" && c[1].isLocked(.username))
            check("profile: absent protocol = AnyConnect, not locked", c[1].vpnProtocol == "anyconnect" && !c[1].isLocked(.vpnProtocol))
            check("profile: menu = configurations with a server", st.menuConfigs().map(\.id) == ["managed:travail", "managed:labo"])
        }
        do {
            let (st, p, _) = make()
            p.store["configurations"] = profile(two)   // present but NOT enforced: ignored
            check("profile not enforced: ignored", st.configs().filter(\.managed).isEmpty)
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile([
                ["name": "", "server": "https://a.example"],
                ["name": "   ", "server": "https://a.example"],
                ["server": "https://sans-nom.example"],
                ["name": "Dup", "server": "https://d1.example"],
                ["name": "dup", "server": "https://d2.example"],
                ["name": "Bad\u{0007}Name  \n  x", "server": "https://b.example", "protocol": "n-importe-quoi", "username": 12],
                ["name": String(repeating: "é", count: 90), "server": "https://long.example"],
                ["name": "Ctrl", "server": "https://c\nscript=/tmp/x"],
                "pas un dictionnaire",
            ])
            let c = st.configs().filter(\.managed)
            check("profile: empty or missing names and invalid entries dropped", c.count == 5, "\(c.map(\.name))")
            check("profile: duplicate names, distinct ids", c[0].id == "managed:dup" && c[1].id == "managed:dup-2", "\(c.map(\.id))")
            check("profile: name cleaned (control characters, spaces)", c[2].name == "BadName x", c[2].name)
            check("profile: unknown protocol = AnyConnect, non-text value ignored", c[2].vpnProtocol == "anyconnect" && !c[2].isLocked(.vpnProtocol) && c[2].username.isEmpty)
            check("profile: name limited to 60 characters", c[3].name.count == 60)
            check("profile: value with a control character rejected", c[4].server.isEmpty && !c[4].isLocked(.server), "\(c[4])")
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            var c = st.configs()
            c[1].username = "ignore"            // locked: must be ignored
            c[0].username = " alice "           // free: stored, spaces trimmed
            c[0].server = "https://pirate.example"   // locked: ignored
            st.save(c)
            let r = st.configs()
            check("override: free field stored", r[0].username == "alice", r[0].username)
            check("override: locked field never changed", r[0].server == "https://vpn.travail.example" && r[1].username == "labuser")
            let ov = p.store[ConfigStore.overridesKey] as? [String: [String: String]] ?? [:]
            check("override: only the free fields are stored", ov["managed:travail"] == ["username": "alice"] && ov["managed:labo"] == [:], "\(ov)")
            check("override: a profile is not stored as a user configuration", (try? JSONDecoder().decode([VPNConfig].self, from: p.store[ConfigStore.userKey] as! Data))?.count == 1)
        }
        do {
            let (st, p, s) = make()
            p.managed["configurations"] = profile(two)
            st.setPassword("pw", for: "managed:travail"); st.setTOTP("jbsw y3dp", for: "managed:travail")
            let before = st.config(id: "managed:travail")
            p.managed = [:]
            check("profile removed: its configurations disappear", st.configs().filter(\.managed).isEmpty && before != nil)
            check("profile removed: the secrets stay in the Keychain", s.items["password.managed:travail"] == "pw")
        }

        // ---- user configurations
        do {
            let (st, _, s) = make()
            var list = st.configs()
            var a = ConfigStore.newUserConfig(); a.name = "  Perso  "; a.server = " https://perso.example "; a.username = " bob "
            list.append(a)
            st.save(list)
            st.setPassword("pwA", for: a.id); st.setTOTP("otpauth://totp/x?secret=jbswy3dp&issuer=y", for: a.id)
            let r = st.configs()
            check("add: stored, name and fields cleaned", r.count == 2 && r[1].name == "Perso" && r[1].server == "https://perso.example" && r[1].username == "bob", "\(r)")
            check("add: secrets under an account of their own", s.items["password.\(a.id)"] == "pwA" && s.items["totp.\(a.id)"] == "JBSWY3DP", "\(s.items)")
            check("add: 'default' keeps the old accounts", ConfigStore.account("password", id: "default") == "password" && ConfigStore.account("totp", id: "default") == "totp")
            st.setPassword("pwD", for: "default")
            var renamed = r; renamed[1].name = "Perso 2"
            st.save(renamed)
            check("rename", st.config(id: a.id)?.name == "Perso 2")
            st.save(Array(renamed.prefix(1)))
            check("delete: configuration removed", st.configs().map(\.id) == ["default"])
            check("delete: its secrets are erased, those of 'default' kept", s.items["password.\(a.id)"] == nil && s.items["totp.\(a.id)"] == nil && s.items["password"] == "pwD", "\(s.items)")
            st.save([])
            check("delete all: empty list, no migration on the next launch", st.configs().isEmpty)
        }
        do {
            let (st, _, _) = make()
            var d = st.configs()[0]; d.name = "\u{0007}  "
            st.save([d])
            check("empty name on save: replaced by a default name", !(st.configs()[0].name.isEmpty))
        }

        // ---- connection request
        do {
            let (st, p, _) = make()
            p.store["server"] = "https://vpn.example.com"; p.store["username"] = "alice"; p.store["protocol"] = "fortinet"
            _ = st.configs()
            check("request: no password → nil", st.request(for: "default") == nil)
            st.setPassword("pw", for: "default")
            check("request: no TOTP → nil", st.request(for: "default") == nil)
            st.setTOTP("JBSWY3DP", for: "default")
            let r = st.request(for: "default")
            check("request: complete", r?.server == "https://vpn.example.com" && r?.vpnProtocol == "fortinet" && r?.username == "alice" && r?.password == "pw" && r?.totpSecret == "JBSWY3DP", "\(String(describing: r))")
            check("request: unknown id → nil", st.request(for: "inconnu") == nil)
            var d = st.configs()[0]; d.username = ""
            st.save([d])
            check("request: no username → nil", st.request(for: "default") == nil)
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            st.setPassword("pw", for: "managed:labo"); st.setTOTP("JBSWY3DP", for: "managed:labo")
            let r = st.request(for: "managed:labo")
            check("request: profile configuration (enforced username)", r?.username == "labuser" && r?.server == "https://vpn.labo.example" && r?.password == "pw", "\(String(describing: r))")
            check("request: the profile's other configuration, without secrets → nil", st.request(for: "managed:travail") == nil)
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            check("menu: empty 'default' hidden when other configurations exist", st.menuConfigs().map(\.id) == ["managed:travail", "managed:labo"])
        }
        do {
            let (st, _, _) = make()
            check("active configuration: none at first", st.activeID == nil)
            st.activeID = "managed:labo"
            check("active configuration: remembered", st.activeID == "managed:labo")
        }

        // ---- helpers
        check("TOTP: otpauth URL", ConfigStore.normalizeTOTP("otpauth://totp/Compte?secret=jbsw-y3dp&issuer=X") == "JBSWY3DP")
        check("TOTP: base32 prefix and spaces", ConfigStore.normalizeTOTP(" base32:jbsw y3dp \n") == "JBSWY3DP")
        check("slug", ConfigStore.slug("Mon VPN (travail)") == "mon-vpn-travail" && ConfigStore.slug("***") == "config" && ConfigStore.slug("Éé") == "config")
        check("name: empty or control characters only → nil", ConfigStore.cleanName(nil) == nil && ConfigStore.cleanName(" \u{0007}\n ") == nil)

        print(failures == 0 ? "\n✔ \(count) checks passed" : "\n✘ \(failures) failure(s) out of \(count)")
        exit(failures == 0 ? 0 : 1)
    }
}
