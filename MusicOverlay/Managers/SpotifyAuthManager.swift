import Foundation
import CryptoKit
import AppKit
import Network

class LocalAuthServer {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8082
    private var activeConnections: [Int: NWConnection] = [:]
    private var nextConnectionID: Int = 0
    var onCallback: ((URL) -> Void)?
    
    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if let ip = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ip), port: port)
            }
            listener = try NWListener(using: parameters)
            
            // Monitor listener state so we know if it actually binds successfully
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[LocalAuthServer] ✅ Listener ready on port 8082")
                case .failed(let error):
                    print("[LocalAuthServer] ❌ Listener failed: \(error)")
                case .cancelled:
                    print("[LocalAuthServer] Listener cancelled")
                case .waiting(let error):
                    print("[LocalAuthServer] ⚠️ Listener waiting: \(error)")
                default:
                    print("[LocalAuthServer] Listener state: \(state)")
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                print("[LocalAuthServer] New connection received")
                self?.handleConnection(connection)
            }
            listener?.start(queue: .main)
            print("[LocalAuthServer] start() called — waiting for .ready state")
        } catch {
            print("[LocalAuthServer] ❌ Failed to create listener: \(error)")
        }
    }
    
    func stop() {
        print("[LocalAuthServer] stop() called")
        listener?.cancel()
        listener = nil
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
    }
    
    private func handleConnection(_ connection: NWConnection) {
        let id = nextConnectionID
        nextConnectionID += 1
        activeConnections[id] = connection
        print("[LocalAuthServer] Handling connection id=\(id)")
        
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
                print("[LocalAuthServer] HTTP request received (\(currentBuffer.count) bytes)")
                self?.processRequest(requestString, connection: connection, id: id)
            } else if error == nil && !isComplete {
                self?.readHTTP(connection: connection, id: id, buffer: currentBuffer)
            } else {
                if let error = error {
                    print("[LocalAuthServer] Read error for id=\(id): \(error)")
                }
                self?.activeConnections.removeValue(forKey: id)
            }
        }
    }
    
    private func processRequest(_ request: String, connection: NWConnection, id: Int) {
        defer {
            activeConnections.removeValue(forKey: id)
        }
        
        // Capture the callback URL before sending the response, so we can fire
        // onCallback *after* the send completes — avoiding a race where stop()
        // cancels the connection while the HTTP response is still in-flight.
        var callbackURL: URL? = nil
        
        let lines = request.components(separatedBy: "\r\n")
        if let firstLine = lines.first, firstLine.hasPrefix("GET ") {
            print("[LocalAuthServer] Request line: \(firstLine)")
            let components = firstLine.components(separatedBy: " ")
            if components.count > 1 {
                let path = components[1]
                print("[LocalAuthServer] Path: \(path)")
                if path.starts(with: "/callback"), let url = URL(string: "http://127.0.0.1:8082\(path)") {
                    print("[LocalAuthServer] ✅ Callback URL parsed: \(url)")
                    callbackURL = url
                } else {
                    print("[LocalAuthServer] ⚠️ Path '\(path)' did not match /callback")
                }
            }
        } else {
            print("[LocalAuthServer] ⚠️ Unexpected request (no GET line)")
        }
        
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authentication successful!</h2><p>You can close this tab and return to MusicOverlay.</p><script>window.close()</script></body></html>"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
            // Cancel the connection first, then fire the callback so stop() can't
            // race with this send operation.
            connection.cancel()
            if let url = callbackURL {
                DispatchQueue.main.async {
                    self.onCallback?(url)
                }
            }
        }))
    }
}

public class SpotifyAuthManager: ObservableObject {
    public static let shared = SpotifyAuthManager()
    
    @Published public var hasValidToken: Bool = false
    @Published public var errorMessage: String? = nil
    
    private let redirectURI = "http://127.0.0.1:8082/callback"
    private let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    
    private var codeVerifier: String = ""
    private var authServer: LocalAuthServer?
    
    private init() {
        checkToken()
    }
    
    public func getClientID() -> String? {
        if let data = KeychainHelper.shared.read(service: "Spotify", account: "ClientID"),
           let id = String(data: data, encoding: .utf8) {
            return id
        }
        return nil
    }
    
    public func setClientID(_ id: String) {
        if let data = id.data(using: .utf8) {
            KeychainHelper.shared.save(data, service: "Spotify", account: "ClientID")
        }
    }
    
    public func checkToken() {
        if KeychainHelper.shared.read(service: "Spotify", account: "AccessToken") != nil {
            hasValidToken = true
            print("[SpotifyAuthManager] Found existing token in keychain → hasValidToken=true")
        } else {
            hasValidToken = false
            print("[SpotifyAuthManager] No token in keychain → hasValidToken=false")
        }
    }
    
    // Generates a random string for PKCE
    private func generateRandomString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    
    public func startAuthFlow() {
        guard let clientID = getClientID(), !clientID.isEmpty else {
            DispatchQueue.main.async { self.errorMessage = "No Client ID set" }
            return
        }
        
        print("[SpotifyAuthManager] startAuthFlow() — clientID=\(clientID)")
        DispatchQueue.main.async { self.errorMessage = nil }
        
        // Stop any existing server before starting a new one
        authServer?.stop()
        authServer = nil
        
        authServer = LocalAuthServer()
        authServer?.onCallback = { [weak self] url in
            print("[SpotifyAuthManager] onCallback fired with URL: \(url)")
            self?.handleCallbackURL(url)
            self?.authServer?.stop()
            self?.authServer = nil
        }
        authServer?.start()
        
        codeVerifier = generateRandomString(length: 64)
        print("[SpotifyAuthManager] codeVerifier generated (length=\(codeVerifier.count))")
        
        guard let data = codeVerifier.data(using: .utf8) else { return }
        let hash = SHA256.hash(data: data)
        let codeChallenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "scope", value: "playlist-read-private playlist-read-collaborative user-modify-playback-state user-read-currently-playing user-read-playback-state")
        ]
        
        guard let url = components.url else {
            print("[SpotifyAuthManager] ❌ Failed to build authorize URL")
            return
        }
        
        print("[SpotifyAuthManager] Opening browser: \(url)")
        NSWorkspace.shared.open(url)
    }
    
    public func handleCallbackURL(_ url: URL) {
        print("[SpotifyAuthManager] handleCallbackURL: \(url)")
        guard url.path == "/callback" else {
            print("[SpotifyAuthManager] ⚠️ Path '\(url.path)' is not /callback — ignoring")
            return
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            print("[SpotifyAuthManager] ❌ Failed to parse URL components")
            return
        }
        
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            print("[SpotifyAuthManager] ❌ Auth error from Spotify: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Auth Error: \(error)"
                NSApp.activate(ignoringOtherApps: true)
                WindowManager.shared.showOnboardingWindow()
            }
            return
        }
        
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let clientID = getClientID() else {
            print("[SpotifyAuthManager] ❌ Missing 'code' param or clientID")
            print("[SpotifyAuthManager]   queryItems: \(components.queryItems ?? [])")
            DispatchQueue.main.async {
                self.errorMessage = "Missing code or clientID"
                NSApp.activate(ignoringOtherApps: true)
                WindowManager.shared.showOnboardingWindow()
            }
            return
        }
        
        print("[SpotifyAuthManager] Got auth code (len=\(code.count)), exchanging for token...")
        
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        
        // Manual form-urlencoded string to ensure correctness
        let bodyString = bodyComponents.queryItems?.compactMap { item in
            guard let value = item.value?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        
        request.httpBody = bodyString?.data(using: .utf8)
        print("[SpotifyAuthManager] Token request body: \(bodyString ?? "(nil)")")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[SpotifyAuthManager] ❌ Network error: \(error)")
                DispatchQueue.main.async {
                    self?.errorMessage = "Network error: \(error.localizedDescription)"
                    NSApp.activate(ignoringOtherApps: true)
                    WindowManager.shared.showOnboardingWindow()
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("[SpotifyAuthManager] Token response HTTP status: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                print("[SpotifyAuthManager] ❌ No data in token response")
                DispatchQueue.main.async {
                    self?.errorMessage = "No data returned"
                    NSApp.activate(ignoringOtherApps: true)
                    WindowManager.shared.showOnboardingWindow()
                }
                return
            }
            
            let rawResponse = String(data: data, encoding: .utf8) ?? "(unreadable)"
            print("[SpotifyAuthManager] Token response body: \(rawResponse)")
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    if let error = json["error"] as? String {
                        let desc = json["error_description"] as? String ?? ""
                        print("[SpotifyAuthManager] ❌ API error: \(error) — \(desc)")
                        DispatchQueue.main.async {
                            self?.errorMessage = "API Error: \(error) - \(desc)"
                            NSApp.activate(ignoringOtherApps: true)
                            WindowManager.shared.showOnboardingWindow()
                        }
                        return
                    }
                    
                    if let accessToken = json["access_token"] as? String {
                        print("[SpotifyAuthManager] ✅ Got access token! Saving to keychain.")
                        KeychainHelper.shared.save(accessToken.data(using: .utf8)!, service: "Spotify", account: "AccessToken")
                        if let refreshToken = json["refresh_token"] as? String {
                            KeychainHelper.shared.save(refreshToken.data(using: .utf8)!, service: "Spotify", account: "RefreshToken")
                            print("[SpotifyAuthManager] ✅ Got refresh token — saved.")
                        }
                        DispatchQueue.main.async {
                            self?.hasValidToken = true
                            print("[SpotifyAuthManager] hasValidToken → true, surfacing onboarding window")
                            NSApp.activate(ignoringOtherApps: true)
                            WindowManager.shared.showOnboardingWindow()
                        }
                    } else {
                        print("[SpotifyAuthManager] ❌ No 'access_token' key in response JSON")
                        DispatchQueue.main.async {
                            self?.errorMessage = "No access token in response"
                            NSApp.activate(ignoringOtherApps: true)
                            WindowManager.shared.showOnboardingWindow()
                        }
                    }
                }
            } catch {
                print("[SpotifyAuthManager] ❌ JSON parse error: \(error)")
                DispatchQueue.main.async {
                    self?.errorMessage = "Failed to parse response"
                    NSApp.activate(ignoringOtherApps: true)
                    WindowManager.shared.showOnboardingWindow()
                }
            }
        }
        task.resume()
    }
}
