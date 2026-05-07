import SwiftUI

public struct DeveloperSettingsView: View {
    @StateObject private var authManager = SpotifyAuthManager.shared
    @State private var clientIDInput: String = ""
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 20) {
            Text("Spotify Developer Settings")
                .font(.headline)
            
            Text("To bypass Spotify's API limits, enter your own Client ID.")
                .font(.caption)
                .multilineTextAlignment(.center)
            
            TextField("Client ID", text: $clientIDInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 300)
            
            Button("Save Client ID") {
                authManager.setClientID(clientIDInput)
            }
            
            if authManager.hasValidToken {
                Text("✅ Logged in successfully!")
                    .foregroundColor(.green)
            } else {
                Button("Login to Spotify") {
                    authManager.startAuthFlow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            if let savedID = authManager.getClientID() {
                clientIDInput = savedID
            }
        }
    }
}
