import Network
import Foundation

class LocalAuthServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8082
    var name: String
    init(name: String) { self.name = name }
    func start() {
        do {
            listener = try NWListener(using: .tcp, on: port)
            listener?.stateUpdateHandler = { state in print("\(self.name) State: \(state)") }
            listener?.start(queue: .main)
        } catch {
            print("\(name) Failed: \(error)")
        }
    }
    func stop() {
        listener?.cancel()
        listener = nil
    }
}

let s1 = LocalAuthServer(name: "s1")
s1.start()
s1.stop()

let s2 = LocalAuthServer(name: "s2")
s2.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
RunLoop.main.run()
