import SwiftUI
import MusicKit

public struct OnboardingView: View {
    @ObservedObject private var authManager = SpotifyAuthManager.shared
    @State private var clientIDInput: String = ""
    @State private var selectedService: String? = nil
    @State private var isAppleMusicAuthorized: Bool = false
    
    // Injected to close the window
    public var onClose: (() -> Void)?
    
    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to MusicOverlay")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Choose your music service to get started.")
                .font(.title3)
                .foregroundColor(.secondary)
            
            HStack(spacing: 40) {
                // Apple Music Button
                Button(action: {
                    selectedService = "appleMusic"
                }) {
                    VStack {
                        if let url = Bundle.main.url(forResource: "apple_music_icon", withExtension: "svg"),
                           let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 60)
                        } else {
                            Image(systemName: "applelogo")
                                .font(.system(size: 60))
                        }
                        Text("Apple Music")
                            .font(.headline)
                            .padding(.top, 5)
                    }
                    .frame(width: 150, height: 120)
                    .background(selectedService == "appleMusic" ? Color.pink.opacity(0.15) : Color.white.opacity(0.05))
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(selectedService == "appleMusic" ? Color.pink.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                
                // Spotify Button
                Button(action: {
                    selectedService = "spotify"
                }) {
                    VStack {
                        if let url = Bundle.main.url(forResource: "spotify_icon", withExtension: "svg"),
                           let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 60)
                        } else {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 60))
                        }
                        Text("Spotify")
                            .font(.headline)
                            .padding(.top, 5)
                    }
                    .frame(width: 150, height: 120)
                    .background(selectedService == "spotify" ? Color.green.opacity(0.15) : Color.white.opacity(0.05))
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(selectedService == "spotify" ? Color.green.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Service-specific configuration
            ZStack(alignment: .top) {
                if selectedService == "appleMusic" {
                    VStack(spacing: 15) {
                        Text("MusicOverlay needs permission to access your Apple Music library.")
                            .multilineTextAlignment(.center)
                        
                        if isAppleMusicAuthorized {
                            Text("✅ Authorized successfully!")
                                .foregroundColor(.green)
                                .onAppear {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        finishOnboarding(with: "appleMusic")
                                    }
                                }
                        } else {
                            Button("Authorize Apple Music") {
                                Task {
                                    let status = await MusicAuthorization.request()
                                    if status == .authorized {
                                        isAppleMusicAuthorized = true
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pink)
                        }
                    }
                    .frame(maxWidth: 350)
                } else if selectedService == "spotify" {
                    VStack(spacing: 8) {
                        VStack(spacing: 4) {
                            Text(.init("1. Create an app on the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/)"))
                            
                            Text("2. Add the Redirect URI below to your app settings:")
                        }
                        .multilineTextAlignment(.center)
                        
                        HStack {
                            Text("Redirect URI:")
                                .font(.body)
                            Text("http://127.0.0.1:8082/callback")
                                .font(.body)
                                .foregroundColor(.secondary)
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("http://127.0.0.1:8082/callback", forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy Redirect URI")
                        }
                        
                        TextField("Client ID", text: $clientIDInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 300)
                            .padding(.top, 5)
                        
                        if authManager.hasValidToken {
                            Text("✅ Logged in successfully!")
                                .foregroundColor(.green)
                        } else {
                            Button("Login to Spotify") {
                                authManager.setClientID(clientIDInput)
                                authManager.startAuthFlow()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(clientIDInput.isEmpty)
                            
                            if let error = authManager.errorMessage {
                                Text(error)
                                    .foregroundColor(.red)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 5)
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                    .onAppear {
                        if let savedID = authManager.getClientID() {
                            clientIDInput = savedID
                        }
                    }
                    // onChange is guaranteed to fire when the @Published value changes,
                    // unlike onAppear which only fires when a view enters the hierarchy.
                    .onChange(of: authManager.hasValidToken) { oldValue, newValue in
                        if newValue {
                            print("[OnboardingView] hasValidToken became true — finishing onboarding in 1s")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                finishOnboarding(with: "spotify")
                            }
                        }
                    }
                }
            }
            .frame(height: 180)
            
            // Tip Note
            VStack(spacing: 2) {
                Text("Tip: Toggle the HUD anytime with **Double-Shift**")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                Text("You can change this later in Settings.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }
            .padding(.top, 5)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 30)
        .frame(width: 600, height: 480)
    }
    
    private func finishOnboarding(with service: String) {
        StateController.shared.preferredService = service
        StateController.shared.onboardingCompleted = true
        StateController.shared.initializeService()
        onClose?()
    }
}
