import Foundation
import Darwin
import CryptoKit

/// Petites briques système utilisées par le helper (processus, réseau, hachage).
enum Sys {
    static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"

    /// Lance un exécutable et renvoie sa sortie (stdout + stderr).
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String]? = nil, input: String? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env ?? ["PATH": safePath]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var inPipe: Pipe?
        if input != nil {
            inPipe = Pipe()
            p.standardInput = inPipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        do { try p.run() } catch { return (-1, "\(error)") }
        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// PID du processus « openconnect » en cours, s'il existe.
    static func openConnectPID() -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return nil }
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            proc_name(pid, &name, UInt32(name.count))
            if String(cString: name) == "openconnect" { return pid }
        }
        return nil
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// Le tunnel est l'interface utun dont l'adresse IPv4 pointe sur elle-même
    /// (la plage attribuée par le serveur varie : 10.250.x, 10.251.x…).
    static func tunnel() -> (name: String, ip: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cur = head
        while let entry = cur {
            let ifa = entry.pointee
            cur = ifa.ifa_next
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("utun"),
                  (ifa.ifa_flags & UInt32(IFF_POINTOPOINT)) != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let dst = ifa.ifa_dstaddr, dst.pointee.sa_family == UInt8(AF_INET),
                  let a = numeric(addr), let d = numeric(dst), a == d else { continue }
            return (name, a)
        }
        return nil
    }

    private static func numeric(_ sa: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    static func sha256(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Dernières lignes d'un fichier texte (pour les messages d'erreur).
    static func tail(_ path: String, lines: Int = 6) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
