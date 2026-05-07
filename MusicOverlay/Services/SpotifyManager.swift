import Foundation

public class SpotifyManager: MediaServiceProtocol {
    
    public init() {}
    
    // MARK: - AppleScript Execution Helper
    
    private func executeAppleScript(_ scriptSource: String) -> String? {
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            let output = script.executeAndReturnError(&error)
            if let error = error {
                print("Spotify AppleScript Error: \(error)")
                return nil
            }
            return output.stringValue
        }
        return nil
    }
    
    // MARK: - MediaServiceProtocol Implementation
    
    public func play() {
        _ = executeAppleScript("tell application \"Spotify\" to play")
    }
    
    public func pause() {
        _ = executeAppleScript("tell application \"Spotify\" to pause")
    }
    
    public func next() {
        _ = executeAppleScript("tell application \"Spotify\" to next track")
    }
    
    public func previous() {
        _ = executeAppleScript("tell application \"Spotify\" to previous track")
    }
    
    public func getCurrentTrack() -> TrackInfo? {
        let script = """
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
        """
        
        guard let result = executeAppleScript(script), !result.isEmpty else {
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
        
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String else {
                return nil
            }
            return Playlist(id: id, name: name, uri: uri)
        }
    }
    
    public func playPlaylist(uri: String) {
        _ = executeAppleScript("tell application \"Spotify\" to play track \"\(uri)\"")
    }
}
