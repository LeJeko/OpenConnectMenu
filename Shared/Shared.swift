import Foundation

/// Constantes et protocole XPC partagés entre l'app et le helper privilégié.
enum Constants {
    static let appBundleID = BuildConfig.bundleID
    static let helperLabel = BuildConfig.bundleID + ".helper"
    static var helperPlist: String { helperLabel + ".plist" }
    static let teamID = BuildConfig.teamID
    static let logPath = "/Library/Logs/OpenConnectMenu.log"

    /// Le helper n'accepte que les connexions de l'app signée par cette équipe.
    static var appRequirement: String {
        "anchor apple generic and identifier \"\(appBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// L'app ne parle qu'au helper signé par cette équipe.
    static var helperRequirement: String {
        "anchor apple generic and identifier \"\(helperLabel)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// Protocoles gérés par openconnect (option --protocol). Liste unique : l'app s'en sert pour le menu des
/// réglages, le helper pour n'accepter que ces valeurs, et build.sh pour valider un profil de configuration.
struct VPNProtocol {
    let id: String
    let label: String
}

extension Constants {
    static let protocols: [VPNProtocol] = [
        VPNProtocol(id: "anyconnect", label: "Cisco AnyConnect / ocserv"),
        VPNProtocol(id: "nc",         label: "Juniper Network Connect"),
        VPNProtocol(id: "gp",         label: "Palo Alto GlobalProtect"),
        VPNProtocol(id: "pulse",      label: "Pulse Connect Secure"),
        VPNProtocol(id: "f5",         label: "F5 BIG-IP"),
        VPNProtocol(id: "fortinet",   label: "Fortinet FortiGate"),
        VPNProtocol(id: "array",      label: "Array Networks"),
    ]
    static let defaultProtocol = "anyconnect"
}

struct ConnectRequest: Codable {
    var server: String
    var vpnProtocol: String?   // absent chez une ancienne app : AnyConnect
    var authgroup: String
    var useragent: String
    var username: String
    var password: String
    var totpSecret: String
}

struct VPNStatus: Codable {
    var running: Bool
    var connected: Bool
    var pid: Int32
    var tunnelInterface: String
    var tunnelIP: String
    var uptime: Double
}

struct TrustInfo: Codable {
    var trusted: Bool
    /// Code stable (oc_missing, oc_not_approved, oc_changed, oc_trusted), traduit par l'app.
    var code: String
    var openconnectPath: String
    var version: String
}

/// Les réponses du helper sont des codes (« oc_exited », « timeout »…), éventuellement suivis d'un détail
/// sur les lignes suivantes. Le helper tourne en root : il ne connaît pas la langue de l'utilisateur,
/// c'est l'app qui traduit.
@objc(HelperProtocol)
protocol HelperProtocol {
    func version(reply: @escaping (String) -> Void)
    func quit()
    func status(reply: @escaping (Data) -> Void)
    func trustInfo(reply: @escaping (Data) -> Void)
    func trust(authorization: Data, reply: @escaping (Bool, String) -> Void)
    func connect(request: Data, reply: @escaping (Bool, String) -> Void)
    func disconnect(reply: @escaping (Bool, String) -> Void)
}
