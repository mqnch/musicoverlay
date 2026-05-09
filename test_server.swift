import Network
import Foundation

class LocalAuthServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8082
    private var activeConnections: [Int: NWConnection] = [:]
    private var nextConnectionID: Int = 0
    
    func start() {
        do {
            let parameters = NWParameters.tcp
            if let ip = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ip), port: port)
            }
            listener = try NWListener(using: parameters)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .main)
            print("Server started")
        } catch {
            print("Failed to start local auth server: \\(error)")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        let id = nextConnectionID
        nextConnectionID += 1
        activeConnections[id] = connection
        
        connection.start(queue: .main)
        readHTTP(connection: connection, id: id, buffer: Data())
    }
    
    private func readHTTP(connection: NWConnection, id: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            var currentBuffer = buffer
            if let data = data {
                currentBuffer.append(data)
            }
            
            if let requestString = String(data: currentBuffer, encoding: .utf8), requestString.contains("\r\n\r\n") {
                self?.processRequest(requestString, connection: connection, id: id)
            } else if error == nil && !isComplete {
                self?.readHTTP(connection: connection, id: id, buffer: currentBuffer)
            } else {
                self?.activeConnections.removeValue(forKey: id)
            }
        }
    }
    
    private func processRequest(_ request: String, connection: NWConnection, id: Int) {
        defer {
            activeConnections.removeValue(forKey: id)
        }
        
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Auth OK</h2></body></html>"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}

let server = LocalAuthServer()
server.start()

RunLoop.main.run()
