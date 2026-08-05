import AppKit
import MusicKit

public class AppleMusicManager: MediaServiceProtocol {
    public var name: String { "Apple Music" }
    
    public init() {}
    
    // MARK: - AppleScript sources
    
    private let playSource = "tell application \"Music\" to play"
    private let pauseSource = "tell application \"Music\" to pause"
    private let nextSource = "tell application \"Music\" to next track"
    private let prevSource = "tell application \"Music\" to previous track"
    
    private let currentTrackSource = """
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
    """
    
    // MARK: - Script execution
    
    /// Dedicated serial queue for all AppleScript work so the blocking Apple
    /// Events IPC never runs on the main thread and `NSAppleScript` instances are
    /// only ever touched from one consistent thread.
    private let scriptQueue = DispatchQueue(label: "com.musicoverlay.applemusic.applescript")
    
    /// Compiled scripts cache. MUST only be accessed from `scriptQueue`, which
    /// serializes every access — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private var compiledScripts: [String: NSAppleScript] = [:]
    
    nonisolated private func isMusicRunning() -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }
    
    /// Fire-and-forget script execution. Returns immediately; the Apple Event is
    /// sent on `scriptQueue`. Used for playback commands, which have no return
    /// value and must never block the caller.
    nonisolated private func runScriptAsync(_ source: String, cache: Bool = true) {
        scriptQueue.async { _ = self.executeScript(source, cache: cache) }
    }

    @discardableResult
    nonisolated private func runScript(_ source: String, cache: Bool = true) -> String? {
        return scriptQueue.sync { executeScript(source, cache: cache) }
    }

    /// Must only ever be called on `scriptQueue`.
    nonisolated private func executeScript(_ source: String, cache: Bool) -> String? {
        guard isMusicRunning() else { return nil }

        let script: NSAppleScript
        if cache, let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: source) else { return nil }
            if cache { compiledScripts[source] = compiled }
            script = compiled
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error = error {
            print("AppleScript Error: \(error)")
            return nil
        }
        return output.stringValue
    }
    
    // MARK: - MediaServiceProtocol Implementation
    
    nonisolated public func play() {
        runScriptAsync(playSource)
    }
    
    nonisolated public func pause() {
        runScriptAsync(pauseSource)
    }
    
    nonisolated public func next() {
        runScriptAsync(nextSource)
    }
    
    nonisolated public func previous() {
        runScriptAsync(prevSource)
    }
    
    nonisolated public func getCurrentTrack() -> TrackInfo? {
        guard let result = runScript(currentTrackSource), !result.isEmpty else {
            return nil
        }
        
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 4 else { return nil }
        
        let durationStr = parts[3]
        let duration = TimeInterval(durationStr) ?? 0.0
        
        // Derive a stable id from track identity so unchanged tracks don't
        // appear as a new track every poll (which would churn SwiftUI state).
        let stableID = "\(parts[0])|\(parts[1])|\(parts[2])"
        
        return TrackInfo(
            id: stableID,
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
        let response = try await request.response()
        
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

    public func playLikedSongs(startIndex: Int) {
        print("AppleMusic playLikedSongs requested at index: \(startIndex)")
    }

    public func search(query: String) async throws -> [SearchResult] {
        // Apple Music search not yet implemented — return empty
        return []
    }

    public func fetchPlaylistTracks(playlistID: String, offset: Int, limit: Int) async throws -> (tracks: [SpotifyTrack], hasMore: Bool) {
        // Apple Music playlist tracks not yet implemented
        return ([], false)
    }

    nonisolated public func setShuffle(_ on: Bool) {
        let value = on ? "true" : "false"
        runScriptAsync("tell application \"Music\" to set shuffle enabled to \(value)", cache: false)
    }

    nonisolated public func setRepeat(_ mode: RepeatMode) {
        let value: String
        switch mode {
        case .off:     value = "off"
        case .track:   value = "one"
        case .context: value = "all"
        }
        runScriptAsync("tell application \"Music\" to set song repeat to \(value)", cache: false)
    }

    nonisolated public func setVolume(_ volume: Double) {
        let clamped = Int(max(0, min(100, volume)))
        runScriptAsync("tell application \"Music\" to set sound volume to \(clamped)", cache: false)
    }

    nonisolated public func seekTo(_ position: TimeInterval) {
        runScriptAsync("tell application \"Music\" to set player position to \(position)", cache: false)
    }
}

