import Foundation

/// Point d'entrée du helper privilégié (LaunchDaemon lancé à la demande par launchd).
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let service = Service()
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: Constants.helperLabel)
// Seule l'app signée par notre équipe peut parler au helper.
listener.setConnectionCodeSigningRequirement(Constants.appRequirement)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
