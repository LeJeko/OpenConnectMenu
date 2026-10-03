import Foundation

// Tests de ConfigStore, sans interface ni vrai Trousseau : ./build.sh test

/// Préférences simulées. `managed` imite le domaine géré d'un profil de configuration : ces valeurs sont lues en
/// priorité, signalées « forcées », et une écriture sur la même clé ne les modifie pas.
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
        // ---- installation neuve et migration
        do {
            let (st, p, _) = make()
            let c = st.configs()
            check("neuf : une seule configuration « default », vide", c.count == 1 && c[0].id == "default" && c[0].server.isEmpty && !c[0].managed)
            check("neuf : rien à proposer dans le menu", st.menuConfigs().isEmpty)
            check("neuf : la migration est enregistrée", p.store[ConfigStore.userKey] is Data)
        }
        do {
            let (st, p, s) = make()
            p.store["server"] = "https://vpn.example.com"; p.store["protocol"] = "gp"; p.store["authgroup"] = "G"
            p.store["useragent"] = "UA"; p.store["username"] = "alice"
            s.items["password"] = "pw"; s.items["totp"] = "JBSWY3DPEHPK3PXP"
            let d = st.configs()[0]
            check("migration : les clés plates deviennent « default »", d.id == "default" && d.server == "https://vpn.example.com" && d.vpnProtocol == "gp" && d.authgroup == "G" && d.useragent == "UA" && d.username == "alice", "\(d)")
            check("migration : secrets conservés sous les anciens comptes", st.password(for: "default") == "pw" && st.totp(for: "default") == "JBSWY3DPEHPK3PXP")
            check("migration : connexion possible sans ressaisie", st.request(for: "default")?.password == "pw")
            p.store["server"] = "https://autre.example.com"
            check("migration : exécutée une seule fois", st.configs()[0].server == "https://vpn.example.com")
            check("migration : les clés plates ne sont pas supprimées", p.store["server"] != nil && p.store["username"] != nil)
        }
        do {
            let (st, p, _) = make()
            p.store[ConfigStore.userKey] = Data("pas du json".utf8)
            let c = st.configs()
            check("données illisibles : une configuration vide, rien d'écrasé", c.count == 1 && c[0].id == "default" && (p.store[ConfigStore.userKey] as? Data) == Data("pas du json".utf8))
        }

        // ---- surcouche des anciennes clés plates imposées
        do {
            let (st, p, _) = make()
            p.store["server"] = "https://mon.vpn"; p.store["username"] = "alice"
            _ = st.configs()
            p.managed["server"] = "https://impose.example.org"; p.managed["protocol"] = "pulse"
            let d = st.configs()[0]
            check("ancien profil : valeurs imposées sur « default »", d.server == "https://impose.example.org" && d.vpnProtocol == "pulse")
            check("ancien profil : champs verrouillés, les autres libres", d.isLocked(.server) && d.isLocked(.vpnProtocol) && !d.isLocked(.username) && d.username == "alice")
            var e = d; e.username = "bob"; e.server = "https://modifie.example"
            st.save([e])
            p.managed = [:]
            let after = st.configs()[0]
            check("ancien profil : la valeur imposée n'est jamais écrite dans les réglages", after.server == "https://mon.vpn" && after.username == "bob", "\(after)")
        }

        // ---- configurations d'un profil
        let two: [[String: Any]] = [
            ["name": "Travail", "server": "https://vpn.travail.example", "protocol": "gp", "authgroup": "Staff", "useragent": "PAN"],
            ["name": "Labo", "server": "https://vpn.labo.example", "username": "labuser"],
        ]
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            let c = st.configs()
            check("profil : deux configurations d'abord, puis « default »", c.map(\.id) == ["managed:travail", "managed:labo", "default"], "\(c.map(\.id))")
            check("profil : lecture seule", c[0].managed && c[1].managed && !c[2].managed)
            check("profil : champs présents verrouillés", c[0].isLocked(.server) && c[0].isLocked(.vpnProtocol) && c[0].isLocked(.authgroup) && c[0].isLocked(.useragent) && !c[0].isLocked(.username))
            check("profil : valeurs lues", c[0].vpnProtocol == "gp" && c[0].authgroup == "Staff" && c[1].username == "labuser" && c[1].isLocked(.username))
            check("profil : protocole absent = AnyConnect, non verrouillé", c[1].vpnProtocol == "anyconnect" && !c[1].isLocked(.vpnProtocol))
            check("profil : menu = configurations avec serveur", st.menuConfigs().map(\.id) == ["managed:travail", "managed:labo"])
        }
        do {
            let (st, p, _) = make()
            p.store["configurations"] = profile(two)   // présent mais NON imposé : ignoré
            check("profil non imposé : ignoré", st.configs().filter(\.managed).isEmpty)
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
            check("profil : noms vides, absents et entrées invalides écartés", c.count == 5, "\(c.map(\.name))")
            check("profil : doublons de noms, identifiants distincts", c[0].id == "managed:dup" && c[1].id == "managed:dup-2", "\(c.map(\.id))")
            check("profil : nom nettoyé (contrôles, espaces)", c[2].name == "BadName x", c[2].name)
            check("profil : protocole inconnu = AnyConnect, valeur non texte ignorée", c[2].vpnProtocol == "anyconnect" && !c[2].isLocked(.vpnProtocol) && c[2].username.isEmpty)
            check("profil : nom limité à 60 caractères", c[3].name.count == 60)
            check("profil : valeur avec caractère de contrôle refusée", c[4].server.isEmpty && !c[4].isLocked(.server), "\(c[4])")
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            var c = st.configs()
            c[1].username = "ignore"            // verrouillé : doit être ignoré
            c[0].username = " alice "           // libre : enregistré, espaces retirés
            c[0].server = "https://pirate.example"   // verrouillé : ignoré
            st.save(c)
            let r = st.configs()
            check("surcharge : champ libre enregistré", r[0].username == "alice", r[0].username)
            check("surcharge : champ verrouillé jamais modifié", r[0].server == "https://vpn.travail.example" && r[1].username == "labuser")
            let ov = p.store[ConfigStore.overridesKey] as? [String: [String: String]] ?? [:]
            check("surcharge : seuls les champs libres sont enregistrés", ov["managed:travail"] == ["username": "alice"] && ov["managed:labo"] == [:], "\(ov)")
            check("surcharge : un profil ne s'enregistre pas comme configuration de l'utilisateur", (try? JSONDecoder().decode([VPNConfig].self, from: p.store[ConfigStore.userKey] as! Data))?.count == 1)
        }
        do {
            let (st, p, s) = make()
            p.managed["configurations"] = profile(two)
            st.setPassword("pw", for: "managed:travail"); st.setTOTP("jbsw y3dp", for: "managed:travail")
            let before = st.config(id: "managed:travail")
            p.managed = [:]
            check("profil retiré : ses configurations disparaissent", st.configs().filter(\.managed).isEmpty && before != nil)
            check("profil retiré : les secrets restent dans le Trousseau", s.items["password.managed:travail"] == "pw")
        }

        // ---- configurations de l'utilisateur
        do {
            let (st, _, s) = make()
            var list = st.configs()
            var a = ConfigStore.newUserConfig(); a.name = "  Perso  "; a.server = " https://perso.example "; a.username = " bob "
            list.append(a)
            st.save(list)
            st.setPassword("pwA", for: a.id); st.setTOTP("otpauth://totp/x?secret=jbswy3dp&issuer=y", for: a.id)
            let r = st.configs()
            check("ajout : enregistré, nom et champs nettoyés", r.count == 2 && r[1].name == "Perso" && r[1].server == "https://perso.example" && r[1].username == "bob", "\(r)")
            check("ajout : secrets sous un compte propre à la configuration", s.items["password.\(a.id)"] == "pwA" && s.items["totp.\(a.id)"] == "JBSWY3DP", "\(s.items)")
            check("ajout : « default » garde les anciens comptes", ConfigStore.account("password", id: "default") == "password" && ConfigStore.account("totp", id: "default") == "totp")
            st.setPassword("pwD", for: "default")
            var renamed = r; renamed[1].name = "Perso 2"
            st.save(renamed)
            check("renommage", st.config(id: a.id)?.name == "Perso 2")
            st.save(Array(renamed.prefix(1)))
            check("suppression : configuration retirée", st.configs().map(\.id) == ["default"])
            check("suppression : ses secrets sont effacés, ceux de « default » conservés", s.items["password.\(a.id)"] == nil && s.items["totp.\(a.id)"] == nil && s.items["password"] == "pwD", "\(s.items)")
            st.save([])
            check("tout supprimer : liste vide, sans migration au lancement suivant", st.configs().isEmpty)
        }
        do {
            let (st, _, _) = make()
            var d = st.configs()[0]; d.name = "\u{0007}  "
            st.save([d])
            check("nom vide à l'enregistrement : remplacé par un nom par défaut", !(st.configs()[0].name.isEmpty))
        }

        // ---- demande de connexion
        do {
            let (st, p, _) = make()
            p.store["server"] = "https://vpn.example.com"; p.store["username"] = "alice"; p.store["protocol"] = "fortinet"
            _ = st.configs()
            check("demande : sans mot de passe → nil", st.request(for: "default") == nil)
            st.setPassword("pw", for: "default")
            check("demande : sans TOTP → nil", st.request(for: "default") == nil)
            st.setTOTP("JBSWY3DP", for: "default")
            let r = st.request(for: "default")
            check("demande : complète", r?.server == "https://vpn.example.com" && r?.vpnProtocol == "fortinet" && r?.username == "alice" && r?.password == "pw" && r?.totpSecret == "JBSWY3DP", "\(String(describing: r))")
            check("demande : identifiant inconnu → nil", st.request(for: "inconnu") == nil)
            var d = st.configs()[0]; d.username = ""
            st.save([d])
            check("demande : sans identifiant → nil", st.request(for: "default") == nil)
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            st.setPassword("pw", for: "managed:labo"); st.setTOTP("JBSWY3DP", for: "managed:labo")
            let r = st.request(for: "managed:labo")
            check("demande : configuration d'un profil (identifiant imposé)", r?.username == "labuser" && r?.server == "https://vpn.labo.example" && r?.password == "pw", "\(String(describing: r))")
            check("demande : l'autre configuration du profil sans secrets → nil", st.request(for: "managed:travail") == nil)
        }
        do {
            let (st, p, _) = make()
            p.managed["configurations"] = profile(two)
            check("menu : « default » vide masquée quand d'autres configurations existent", st.menuConfigs().map(\.id) == ["managed:travail", "managed:labo"])
        }
        do {
            let (st, _, _) = make()
            check("configuration active : aucune au départ", st.activeID == nil)
            st.activeID = "managed:labo"
            check("configuration active : mémorisée", st.activeID == "managed:labo")
        }

        // ---- outils
        check("TOTP : URL otpauth", ConfigStore.normalizeTOTP("otpauth://totp/Compte?secret=jbsw-y3dp&issuer=X") == "JBSWY3DP")
        check("TOTP : préfixe base32 et espaces", ConfigStore.normalizeTOTP(" base32:jbsw y3dp \n") == "JBSWY3DP")
        check("slug", ConfigStore.slug("Mon VPN (travail)") == "mon-vpn-travail" && ConfigStore.slug("***") == "config" && ConfigStore.slug("Éé") == "config")
        check("nom : vide ou contrôles seuls → nil", ConfigStore.cleanName(nil) == nil && ConfigStore.cleanName(" \u{0007}\n ") == nil)

        print(failures == 0 ? "\n✔ \(count) vérifications passées" : "\n✘ \(failures) échec(s) sur \(count)")
        exit(failures == 0 ? 0 : 1)
    }
}
