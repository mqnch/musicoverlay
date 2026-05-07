import Foundation

public class SpotifyManager: MediaServiceProtocol {
    
    public init() {}
    
    // MARK: - API Cache
    private var cachedPlaylists: [Playlist] = []
    private var cacheExpiration: Date = Date.distantPast
    
    // MARK: - Precompiled AppleScripts
    
    private let playScript = NSAppleScript(source: "tell application \"Spotify\" to play")
    private let pauseScript = NSAppleScript(source: "tell application \"Spotify\" to pause")
    private let nextScript = NSAppleScript(source: "tell application \"Spotify\" to next track")
    private let prevScript = NSAppleScript(source: "tell application \"Spotify\" to previous track")
    
    private let currentTrackScript = NSAppleScript(source: """
    tell application "Spotify"
        if player state is playing then
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDuration to duration of current track
            -- Spotify reports duration in milliseconds, convert to seconds here or in Swift
            return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & (tDuration / 1000.0)
        end if
        return ""
    end tell
    """)
    
    private func executeCompiledScript(_ script: NSAppleScript?) -> String? {
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error)
        if let error = error {
            print("Spotify AppleScript Error: \\(error)")
            return nil
        }
        return output?.stringValue
    }
    
    // Used for dynamic scripts like playPlaylist
    private func executeDynamicAppleScript(_ scriptSource: String) -> String? {
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            let output = script.executeAndReturnError(&error)
            if let error = error {
                print("Spotify AppleScript Error: \\(error)")
                return nil
            }
            return output.stringValue
        }
        return nil
    }
    
    // MARK: - MediaServiceProtocol Implementation
    
    public func play() {
        _ = executeCompiledScript(playScript)
    }
    
    public func pause() {
        _ = executeCompiledScript(pauseScript)
    }
    
    public func next() {
        _ = executeCompiledScript(nextScript)
    }
    
    public func previous() {
        _ = executeCompiledScript(prevScript)
    }
    
    public func getCurrentTrack() -> TrackInfo? {
        guard let result = executeCompiledScript(currentTrackScript), !result.isEmpty else {
            return nil
        }
        
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 4 else { return nil }
        
        let durationStr = parts[3]
        let duration = TimeInterval(durationStr) ?? 0.0
        
        return TrackInfo(
            id: UUID().uuidString,
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            duration: duration,
            albumArtURL: nil
        )
    }
    
    public func fetchPlaylists() async throws -> [Playlist] {
        if Date() < cacheExpiration && !cachedPlaylists.isEmpty {
            return cachedPlaylists
        }
        
        guard let tokenData = KeychainHelper.shared.read(service: "Spotify", account: "AccessToken"),
              let token = String(data: tokenData, encoding: .utf8) else {
            return []
        }
        
        guard let url = URL(string: "https://api.spotify.com/v1/me/playlists") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        let playlists = items.compactMap { item -> Playlist? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String else {
                return nil
            }
            return Playlist(id: id, name: name, uri: uri)
        }
        
        self.cachedPlaylists = playlists
        self.cacheExpiration = Date().addingTimeInterval(300) // 5 minutes
        
        return playlists
    }
    
    public func playPlaylist(uri: String) {
        _ = executeDynamicAppleScript("tell application \"Spotify\" to play track \"\(uri)\"")
    }
}
