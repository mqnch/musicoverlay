import Foundation
import MusicKit

public class AppleMusicManager: MediaServiceProtocol {
    
    public init() {}
    
    // MARK: - Precompiled AppleScripts
    
    private let playScript = NSAppleScript(source: "tell application \"Music\" to play")
    private let pauseScript = NSAppleScript(source: "tell application \"Music\" to pause")
    private let nextScript = NSAppleScript(source: "tell application \"Music\" to next track")
    private let prevScript = NSAppleScript(source: "tell application \"Music\" to previous track")
    
    private let currentTrackScript = NSAppleScript(source: """
    tell application "Music"
        if player state is playing then
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDuration to duration of current track
            return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tDuration
        end if
        return ""
    end tell
    """)
    
    private func executeCompiledScript(_ script: NSAppleScript?) -> String? {
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error)
        if let error = error {
            print("AppleScript Error: \\(error)")
            return nil
        }
        return output?.stringValue
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
            albumArtURL: nil // AppleScript artwork fetching is slow, handled separately later if needed
        )
    }
    
    public func fetchPlaylists() async throws -> [Playlist] {
        // Request authorization
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            print("MusicKit Authorization Denied")
            return []
        }
        
        // Fetch library playlists via MusicKit
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.limit = 50 // Optional: limit the number of playlists fetched initially
        
        let response = try await request.response()
        
        return response.items.map { mkPlaylist in
            Playlist(
                id: mkPlaylist.id.rawValue,
                name: mkPlaylist.name,
                uri: mkPlaylist.id.rawValue // Storing ID in URI to use later
            )
        }
    }
    
    public func playPlaylist(uri: String) {
        // If we only have the ID, we might need a workaround for AppleScript,
        // but for now, if the URI is the name, we can do:
        // executeAppleScript("tell application \"Music\" to play user playlist \"\(uri)\"")
        // Since we stored the ID in the URI above, a full implementation would map ID -> Name 
        // or just rely on MusicKit's ApplicationMusicPlayer (macOS 12+).
        
        print("Play playlist requested for ID: \\(uri)")
    }
}
