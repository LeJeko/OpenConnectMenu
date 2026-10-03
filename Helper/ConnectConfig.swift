import Foundation

/// Valide une demande de connexion venue de l'app et fabrique le fichier de configuration d'openconnect.
/// Rien de ce que l'app envoie n'est utilisé tel quel : chaque champ est contrôlé ici, par le helper.
enum ConnectConfig {
    /// Retourne le contenu du fichier de configuration, ou nil si la demande est invalide.
    /// (Le mot de passe n'y figure pas : il passe par l'entrée standard.)
    static func make(_ req: ConnectRequest) -> String? {
        guard let server = clean(req.server), server.hasPrefix("https://"),
              let user = clean(req.username),
              let secret = clean(req.totpSecret),
              secret.range(of: "^[A-Z2-7]+=*$", options: .regularExpression) != nil,
              !req.password.isEmpty, !req.password.contains("\n") else { return nil }

        // Protocole : liste fermée (jamais une valeur libre) ; absent = AnyConnect.
        let rawProtocol = (req.vpnProtocol ?? "").trimmingCharacters(in: .whitespaces)
        let proto = rawProtocol.isEmpty ? Constants.defaultProtocol : rawProtocol
        guard Constants.protocols.contains(where: { $0.id == proto }) else { return nil }

        // Groupe d'authentification et User-Agent : facultatifs, mais valides s'ils sont renseignés.
        // Sans User-Agent, openconnect en choisit un adapté au protocole.
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
