import Foundation

public protocol MediaServiceProtocol {
    // MARK: - Basic playback
    func play()
    func pause()
    func next()
    func previous()
    func getCurrentTrack() -> TrackInfo?

    // MARK: - Playlist fetching
    func fetchPlaylists() async throws -> [Playlist]

    // MARK: - Search
    func search(query: String) async throws -> [SearchResult]

    // MARK: - Playlist drill-down
    func fetchPlaylistTracks(playlistID: String) async throws -> [SpotifyTrack]

    // MARK: - Playback commands
    func playPlaylist(uri: String)
    func playTrack(uri: String)
    func setShuffle(_ on: Bool)
    func setRepeat(_ mode: RepeatMode)

    // MARK: - Volume & seeking
    func setVolume(_ volume: Double)   // 0–100
    func seekTo(_ position: TimeInterval)
}
