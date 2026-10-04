import Foundation

/// Validates a connection request coming from the app and builds openconnect's configuration file.
/// Nothing the app sends is used as is: every field is checked here, by the helper.
enum ConnectConfig {
    /// Returns the content of the configuration file, or nil if the request is invalid.
    /// (The password is not in it: it goes through standard input.)
    static func make(_ req: ConnectRequest) -> String? {
        guard let server = clean(req.server), server.hasPrefix("https://"),
              let user = clean(req.username),
              let secret = clean(req.totpSecret),
              secret.range(of: "^[A-Z2-7]+=*$", options: .regularExpression) != nil,
              !req.password.isEmpty, !req.password.contains("\n") else { return nil }

        // Protocol: closed list (never a free value); absent = AnyConnect.
        let rawProtocol = (req.vpnProtocol ?? "").trimmingCharacters(in: .whitespaces)
        let proto = rawProtocol.isEmpty ? Constants.defaultProtocol : rawProtocol
        guard Constants.protocols.contains(where: { $0.id == proto }) else { return nil }

        // Authentication group and User-Agent: optional, but valid if provided.
        // Without a User-Agent, openconnect picks one suited to the protocol.
        let group = optional(req.authgroup)
        let agent = optional(req.useragent)
        guard group.valid, agent.valid else { return nil }

        var lines = ["server=\(server)", "user=\(user)", "protocol=\(proto)"]
        if let g = group.value { lines.append("authgroup=\(g)") }
        if let a = agent.value { lines.append("useragent=\(a)") }
        lines += ["token-mode=totp", "token-secret=base32:\(secret)"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clean(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return t
    }

    private static func optional(_ raw: String) -> (valid: Bool, value: String?) {
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return (true, nil) }
        guard let c = clean(raw) else { return (false, nil) }
        return (true, c)
    }
}
