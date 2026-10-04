import Foundation

/// Entry point of the privileged helper (LaunchDaemon started on demand by launchd).
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
// Only the app signed by our team can talk to the helper.
listener.setConnectionCodeSigningRequirement(Constants.appRequirement)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
