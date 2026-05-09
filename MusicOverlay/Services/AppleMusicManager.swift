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
        request.limit = 50 
        
        var allPlaylists: [Playlist] = []
        var response = try await request.response()
        
        func mapPlaylist(_ mkPlaylist: MusicKit.Playlist) -> Playlist {
            Playlist(
                id: mkPlaylist.id.rawValue,
                name: mkPlaylist.name,
                uri: mkPlaylist.id.rawValue
            )
        }
        
        allPlaylists.append(contentsOf: response.items.map(mapPlaylist))
        
        var currentItems = response.items
        while currentItems.hasNextBatch, let nextBatch = try await currentItems.nextBatch() {
            allPlaylists.append(contentsOf: nextBatch.map(mapPlaylist))
            currentItems = nextBatch
        }
        
        return allPlaylists
    }
    
    public func playPlaylist(uri: String) {
        print("AppleMusic playPlaylist requested for ID: \(uri)")
    }

    public func playTrack(uri: String, contextUri: String?) {
        print("AppleMusic playTrack requested for URI: \(uri) (context: \(contextUri ?? "none"))")
    }

    public func search(query: String) async throws -> [SearchResult] {
        // Apple Music search not yet implemented — return empty
        return []
    }

    public func fetchPlaylistTracks(playlistID: String) async throws -> [SpotifyTrack] {
        // Apple Music playlist tracks not yet implemented
        return []
    }

    public func setShuffle(_ on: Bool) {
        let value = on ? "true" : "false"
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to set shuffle enabled to \(value)")?.executeAndReturnError(&error)
    }

    public func setRepeat(_ mode: RepeatMode) {
        let value = mode.isActive ? "1" : "0"
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to set song repeat to \(value)")?.executeAndReturnError(&error)
    }

    public func setVolume(_ volume: Double) {
        let clamped = Int(max(0, min(100, volume)))
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to set sound volume to \(clamped)")?.executeAndReturnError(&error)
    }

    public func seekTo(_ position: TimeInterval) {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Music\" to set player position to \(position)")?.executeAndReturnError(&error)
    }
}

