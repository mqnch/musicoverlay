import Foundation

public protocol MediaServiceProtocol {
    func play()
    func pause()
    func next()
    func previous()
    func getCurrentTrack() -> TrackInfo?
    func fetchPlaylists() async throws -> [Playlist]
    func playPlaylist(uri: String)
}
