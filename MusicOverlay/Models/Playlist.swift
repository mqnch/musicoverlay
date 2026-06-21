import Foundation

public struct Playlist: Identifiable, Equatable {
    /// Sentinel id for the synthetic "Liked Songs" pseudo-playlist.
    public static let likedSongsID = "musicoverlay.liked"

    public let id: String
    public let name: String
    public let uri: String
    public let imageURL: URL?
    public let trackCount: Int?
    public var lastPlayed: Date?

    /// True when this is the synthetic Liked Songs collection rather than a real playlist.
    public var isLikedSongs: Bool { id == Playlist.likedSongsID }

    public init(id: String, name: String, uri: String, imageURL: URL? = nil, trackCount: Int? = nil, lastPlayed: Date? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
        self.imageURL = imageURL
        self.trackCount = trackCount
        self.lastPlayed = lastPlayed
    }
}
