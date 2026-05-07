import Foundation
import CryptoKit
import AuthenticationServices
import AppKit

public class SpotifyAuthManager: ObservableObject {
    public static let shared = SpotifyAuthManager()
    
    @Published public var hasValidToken: Bool = false
    
    private let redirectURI = "musicoverlay://callback"
    private let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    
    private var codeVerifier: String = ""
    
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
        } else {
            hasValidToken = false
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
            print("No Client ID set")
            return
        }
        
        codeVerifier = generateRandomString(length: 64)
        
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
            URLQueryItem(name: "scope", value: "playlist-read-private playlist-read-collaborative")
        ]
        
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func handleCallbackURL(_ url: URL) {
        guard url.scheme == "musicoverlay", url.host == "callback" else { return }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let clientID = getClientID() else {
            return
        }
        
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
        
        request.httpBody = bodyComponents.query?.data(using: .utf8)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil else { return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let accessToken = json["access_token"] as? String {
                    KeychainHelper.shared.save(accessToken.data(using: .utf8)!, service: "Spotify", account: "AccessToken")
                    if let refreshToken = json["refresh_token"] as? String {
                        KeychainHelper.shared.save(refreshToken.data(using: .utf8)!, service: "Spotify", account: "RefreshToken")
                    }
                    DispatchQueue.main.async {
                        self?.hasValidToken = true
                    }
                }
            } catch {
                print("Failed to parse token response")
            }
        }
        task.resume()
    }
}
