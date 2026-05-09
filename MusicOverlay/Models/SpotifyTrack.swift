import Foundation

public struct SpotifyTrack: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let uri: String
    public let albumArtURL: URL?
    public let durationMs: Int

    public init(id: String, title: String, artist: String, album: String,
                uri: String, albumArtURL: URL? = nil, durationMs: Int = 0) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.uri = uri
        self.albumArtURL = albumArtURL
        self.durationMs = durationMs
    }

    /// Human-readable duration e.g. "3:42"
    public var durationString: String {
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
