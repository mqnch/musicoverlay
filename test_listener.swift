import Network
import Foundation

let port: NWEndpoint.Port = 8082
let parameters = NWParameters.tcp
if let ip = IPv4Address("127.0.0.1") {
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ip), port: port)
}
do {
    let listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { state in
        print("State: \\(state)")
    }
    listener.start(queue: .main)
    print("Started listener")
} catch {
    print("Error: \\(error)")
}

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    exit(0)
}
RunLoop.main.run()
