import Foundation

/// Constants and XPC protocol shared between the app and the privileged helper.
enum Constants {
    static let appBundleID = BuildConfig.bundleID
    static let helperLabel = BuildConfig.bundleID + ".helper"
    static var helperPlist: String { helperLabel + ".plist" }
    static let teamID = BuildConfig.teamID
    static let logPath = "/Library/Logs/OpenConnectMenu.log"

    /// The helper only accepts connections from the app signed by this team.
    static var appRequirement: String {
        "anchor apple generic and identifier \"\(appBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The app only talks to the helper signed by this team.
    static var helperRequirement: String {
        "anchor apple generic and identifier \"\(helperLabel)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// Protocols handled by openconnect (--protocol option). Single list: the app uses it for the settings
/// menu, the helper to accept only these values, and build.sh to validate a configuration profile.
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
    var vpnProtocol: String?   // absent from an old app: AnyConnect
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
    /// Stable code (oc_missing, oc_not_approved, oc_changed, oc_trusted), translated by the app.
    var code: String
    var openconnectPath: String
    var version: String
}

/// The helper's replies are codes ("oc_exited", "timeout"…), optionally followed by a detail
/// on the following lines. The helper runs as root: it does not know the user's language,
/// so the app does the translating.
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
