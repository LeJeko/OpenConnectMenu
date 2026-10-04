import Foundation
import Security

/// Pinning of openconnect and vpnc-script: the helper (root) only runs them
/// if their SHA-256 matches the one approved by the administrator.
/// Known limitation: Homebrew libraries (GnuTLS…) are not covered.
struct TrustRecord: Codable {
    var openconnectPath: String
    var openconnectSHA256: String
    var scriptPath: String
    var scriptSHA256: String
    var version: String
    var date: Date
}

enum Trust {
    static let dir = "/Library/Application Support/OpenConnectMenu"
    static let file = dir + "/trust.json"

    struct Binaries {
        var openconnect: String
        var script: String
        var version: String
    }

    /// Looks for openconnect and its vpnc-script in the usual Homebrew prefixes.
    static func locate() -> Binaries? {
        let fm = FileManager.default
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let oc = prefix + "/bin/openconnect"
            let script = prefix + "/etc/vpnc/vpnc-script"
            guard fm.isExecutableFile(atPath: oc), fm.fileExists(atPath: script) else { continue }
            let realOC = URL(fileURLWithPath: oc).resolvingSymlinksInPath().path
            let realScript = URL(fileURLWithPath: script).resolvingSymlinksInPath().path
            return Binaries(openconnect: realOC, script: realScript, version: version(fromPath: realOC))
        }
        return nil
    }

    /// The version is read from the path (…/Cellar/openconnect/9.21/…), without running the binary.
    private static func version(fromPath path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let c = parts.firstIndex(of: "Cellar"), c + 2 < parts.count, parts[c + 1] == "openconnect" {
            return parts[c + 2]
        }
        return "inconnue"
    }

    static func load() -> TrustRecord? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TrustRecord.self, from: data)
    }

    /// Current trust state, compared with the binaries currently installed.
    static func check() -> (info: TrustInfo, binaries: Binaries?) {
        guard let b = locate() else {
            return (TrustInfo(trusted: false, code: "oc_missing", openconnectPath: "", version: ""), nil)
        }
        guard let rec = load() else {
            return (TrustInfo(trusted: false, code: "oc_not_approved", openconnectPath: b.openconnect, version: b.version), b)
        }
        let ocHash = Sys.sha256(of: b.openconnect)
        let scriptHash = Sys.sha256(of: b.script)
        if rec.openconnectPath == b.openconnect, rec.scriptPath == b.script,
           rec.openconnectSHA256 == ocHash, rec.scriptSHA256 == scriptHash {
            return (TrustInfo(trusted: true, code: "oc_trusted", openconnectPath: b.openconnect, version: b.version), b)
        }
        return (TrustInfo(trusted: false, code: "oc_changed", openconnectPath: b.openconnect, version: b.version), b)
    }

    /// Records the current hashes (called only after the admin rights have been verified).
    static func approveCurrent() -> (Bool, String) {
        guard let b = locate() else { return (false, "oc_missing") }
        guard let ocHash = Sys.sha256(of: b.openconnect), let scriptHash = Sys.sha256(of: b.script) else {
            return (false, "oc_unreadable")
        }
        let rec = TrustRecord(openconnectPath: b.openconnect, openconnectSHA256: ocHash,
                              scriptPath: b.script, scriptSHA256: scriptHash,
                              version: b.version, date: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fm = FileManager.default
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
            try enc.encode(rec).write(to: URL(fileURLWithPath: file), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: file)
            return (true, "approved")
        } catch {
            return (false, "write_failed\n\(error.localizedDescription)")
        }
    }

    /// Checks that an authorization coming from the app really grants administrator rights.
    static func verifyAdmin(_ data: Data) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = data.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        var granted = false
        "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { ip in
                var rights = AuthorizationRights(count: 1, items: ip)
                // Non-interactive: succeeds only if the app has already obtained the right.
                granted = AuthorizationCopyRights(ref, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
        return granted
    }
}
