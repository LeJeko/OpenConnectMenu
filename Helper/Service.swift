import Foundation
import Darwin

/// Implémentation du protocole XPC, exécutée en root par le helper.
final class Service: NSObject, HelperProtocol {
    private let queue = DispatchQueue(label: "openconnectmenu.ops")
    private let runDir = "/var/run/openconnectmenu"
    private var child: Process?

    // MARK: - Informations

    func version(reply: @escaping (String) -> Void) { reply(buildStamp) }

    func quit() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    func status(reply: @escaping (Data) -> Void) {
        let pid = Sys.openConnectPID()
        let tun = Sys.tunnel()
        var uptime = 0.0
        if let pid, let start = Sys.startTime(of: pid) { uptime = Date().timeIntervalSince(start) }
        let s = VPNStatus(running: pid != nil, connected: pid != nil && tun != nil, pid: pid ?? 0,
                          tunnelInterface: tun?.name ?? "", tunnelIP: tun?.ip ?? "", uptime: uptime)
        reply((try? JSONEncoder().encode(s)) ?? Data())
    }

    func trustInfo(reply: @escaping (Data) -> Void) {
        reply((try? JSONEncoder().encode(Trust.check().info)) ?? Data())
    }

    func trust(authorization: Data, reply: @escaping (Bool, String) -> Void) {
        guard Trust.verifyAdmin(authorization) else {
            reply(false, "admin_not_confirmed")
            return
        }
        let (ok, msg) = Trust.approveCurrent()
        reply(ok, msg)
    }

    // MARK: - Connexion

    func connect(request: Data, reply: @escaping (Bool, String) -> Void) {
        queue.async {
            let (ok, msg) = self.doConnect(request)
            reply(ok, msg)
        }
    }

    private func doConnect(_ data: Data) -> (Bool, String) {
        guard let req = try? JSONDecoder().decode(ConnectRequest.self, from: data),
              let conf = ConnectConfig.make(req) else {
            return (false, "invalid_settings")
        }

        let (info, binaries) = Trust.check()
        guard info.trusted, let bins = binaries else { return (false, info.code) }

        if Sys.openConnectPID() != nil { return (true, "already_connected") }

        // Configuration temporaire réservée à root (elle contient le secret TOTP).
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return (false, "runtime_dir_failed\n\(error.localizedDescription)") }
        let confPath = "\(runDir)/\(UUID().uuidString).conf"
        guard fm.createFile(atPath: confPath, contents: Data(conf.utf8), attributes: [.posixPermissions: 0o600]) else {
            return (false, "config_write_failed")
        }
        defer { try? fm.removeItem(atPath: confPath) }

        // Journal lisible par l'utilisateur (aucun secret n'y est écrit par openconnect).
        fm.createFile(atPath: Constants.logPath, contents: nil, attributes: [.posixPermissions: 0o644])
        guard let log = FileHandle(forWritingAtPath: Constants.logPath) else { return (false, "log_unavailable") }
        try? log.truncate(atOffset: 0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bins.openconnect)
        p.arguments = ["--config=\(confPath)", "--script=\(bins.script)", "--passwd-on-stdin"]
        p.environment = ["PATH": Sys.safePath]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = log
        p.standardError = log
        do { try p.run() } catch { return (false, "launch_failed\n\(error.localizedDescription)") }
        child = p
        stdin.fileHandleForWriting.write(Data((req.password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()

        // Attente de l'établissement du tunnel (40 s max).
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if Sys.tunnel() != nil, Sys.openConnectPID() != nil { return (true, "connected") }
            if !p.isRunning {
                let why = Sys.tail(Constants.logPath)
                return (false, "oc_exited\n\(why)")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return (false, "timeout\n\(Sys.tail(Constants.logPath))")
    }

    // MARK: - Déconnexion

    func disconnect(reply: @escaping (Bool, String) -> Void) {
        queue.async {
            let (ok, msg) = self.doDisconnect()
            reply(ok, msg)
        }
    }

    private func waitForExit(_ pid: Int32, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !Sys.isAlive(pid) || Sys.openConnectPID() != pid { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// openconnect 9.21 sous macOS 27 (bêta) ne réagit à aucun signal : on tente SIGTERM,
    /// puis on rejoue à la main le nettoyage du vpnc-script (route par défaut, DNS)
    /// avant de forcer l'arrêt et de retirer les routes d'exclusion.
    private func doDisconnect() -> (Bool, String) {
        guard let pid = Sys.openConnectPID() else { return (true, "disconnected") }
        let tun = Sys.tunnel()

        kill(pid, SIGTERM)
        if waitForExit(pid, seconds: 2) { return (true, "disconnected") }

        guard let tun, let bins = Trust.check().binaries else {
            return (false, "disconnect_unresponsive")
        }

        // Passerelle d'origine sauvegardée par le vpnc-script.
        let gw = (try? String(contentsOfFile: "/var/run/vpnc/defaultroute.\(pid)", encoding: .utf8))?
            .split(separator: " ").first.map(String.init) ?? ""

        // Routes d'exclusion (Microsoft, Zoom…) ajoutées via l'ancienne passerelle.
        var routes: [(kind: String, dest: String)] = []
        if !gw.isEmpty {
            for line in Sys.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output.split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 4, f[1] == gw, f[2].contains("S"), f[0] != "default" else { continue }
                routes.append((f[2].contains("H") ? "host" : "net", f[0]))
            }
        }

        // DNS installés par le script sur l'interface du tunnel.
        let scutil = Sys.run("/usr/sbin/scutil", [], input: "show State:/Network/Service/\(tun.name)/DNS\n").output
        var dns: [String] = []
        for token in scutil.split(whereSeparator: { !($0.isNumber || $0 == ".") }) {
            let octets = token.split(separator: ".", omittingEmptySubsequences: false)
            let ip = String(token)
            if octets.count == 4, octets.allSatisfy({ Int($0).map { $0 <= 255 } ?? false }), !dns.contains(ip) {
                dns.append(ip)
            }
        }

        var env = ["PATH": Sys.safePath, "reason": "disconnect", "TUNDEV": tun.name, "VPNPID": String(pid),
                   "INTERNAL_IP4_ADDRESS": tun.ip, "INTERNAL_IP4_DNS": dns.joined(separator: " ")]
        env["LOG_LEVEL"] = "1"
        Sys.run(bins.script, [], env: env)
        kill(pid, SIGKILL)
        for r in routes { Sys.run("/sbin/route", ["-n", "delete", "-\(r.kind)", r.dest]) }

        return waitForExit(pid, seconds: 3) ? (true, "disconnected") : (false, "oc_not_stopped")
    }
}
