import Foundation
import Security

/// Client XPC vers le helper privilégié.
final class HelperClient {
    private var connection: NSXPCConnection?

    private func makeConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: Constants.helperLabel, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // On ne parle qu'à un helper signé par notre équipe.
        c.setCodeSigningRequirement(Constants.helperRequirement)
        c.invalidationHandler = { [weak self] in self?.connection = nil }
        c.interruptionHandler = { [weak self] in self?.connection = nil }
        c.resume()
        connection = c
        return c
    }

    /// Exécute un appel XPC ; `fallback` est renvoyé si la connexion échoue.
    private func call<T>(fallback: T, _ body: @escaping (HelperProtocol, @escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let lock = NSLock()
            var done = false
            let finish: (T) -> Void = { value in
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: value)
            }
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { _ in finish(fallback) } as? HelperProtocol
            guard let proxy else { finish(fallback); return }
            body(proxy, finish)
        }
    }

    /// Abandonne la connexion en cours (après une réparation du helper, par exemple).
    func reset() {
        connection?.invalidate()
        connection = nil
    }

    func version() async -> String? {
        await call(fallback: nil) { p, done in p.version { done($0) } }
    }

    func quit() {
        (makeConnection().remoteObjectProxy as? HelperProtocol)?.quit()
        connection?.invalidate()
        connection = nil
    }

    func status() async -> VPNStatus? {
        await call(fallback: nil) { p, done in
            p.status { done(try? JSONDecoder().decode(VPNStatus.self, from: $0)) }
        }
    }

    func trustInfo() async -> TrustInfo? {
        await call(fallback: nil) { p, done in
            p.trustInfo { done(try? JSONDecoder().decode(TrustInfo.self, from: $0)) }
        }
    }

    func trust(authorization: Data) async -> (Bool, String) {
        await call(fallback: (false, "helper_unreachable")) { p, done in
            p.trust(authorization: authorization) { done(($0, $1)) }
        }
    }

    func connect(_ request: ConnectRequest) async -> (Bool, String) {
        guard let data = try? JSONEncoder().encode(request) else { return (false, "bad_request") }
        return await call(fallback: (false, "helper_unreachable")) { p, done in
            p.connect(request: data) { done(($0, $1)) }
        }
    }

    func disconnect() async -> (Bool, String) {
        await call(fallback: (false, "helper_unreachable")) { p, done in
            p.disconnect { done(($0, $1)) }
        }
    }
}

/// Droits administrateur, demandés par l'app (fenêtre système) et vérifiés par le helper.
enum AdminAuth {
    static func externalForm() -> Data? {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        var granted = false
        "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { ip in
                var rights = AuthorizationRights(count: 1, items: ip)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                granted = AuthorizationCopyRights(ref, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
        guard granted else { return nil }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else { return nil }
        return withUnsafeBytes(of: &form) { Data($0) }
    }
}
