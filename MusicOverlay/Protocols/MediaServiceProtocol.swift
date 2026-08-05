import Foundation

public protocol MediaServiceProtocol {
    var name: String { get }
    // MARK: - Basic playback
    func play()
    func pause()
    func next()
    func previous()
    /// Polled every 0.5s. `nonisolated` is load-bearing: this project builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it the blocking
    /// Apple Events IPC inside implementations runs on the main thread even when
    /// the caller wraps it in `Task.detached` — which froze the UI twice a second.
    nonisolated func getCurrentTrack() -> TrackInfo?

    // MARK: - Playlist fetching
    func fetchPlaylists() async throws -> [Playlist]

    // MARK: - Search
    func search(query: String) async throws -> [SearchResult]

    // MARK: - Playlist drill-down
    /// Fetches a window of tracks starting at `offset` (up to `limit`),
    /// returning whether more tracks remain after this window.
    func fetchPlaylistTracks(playlistID: String, offset: Int, limit: Int) async throws -> (tracks: [SpotifyTrack], hasMore: Bool)

    // MARK: - Playback commands
    func playPlaylist(uri: String)
    func playTrack(uri: String, contextUri: String?)
    func playLikedSongs(startIndex: Int)
    func setShuffle(_ on: Bool)
    func setRepeat(_ mode: RepeatMode)

    // MARK: - Volume & seeking
    func setVolume(_ volume: Double)   // 0–100
    func seekTo(_ position: TimeInterval)
}
