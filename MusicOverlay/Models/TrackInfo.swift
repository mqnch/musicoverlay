import Foundation

public struct TrackInfo: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let albumArtURL: URL?
    
    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, albumArtURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.albumArtURL = albumArtURL
    }
}
