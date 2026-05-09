import Foundation

public struct Playlist: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let uri: String
    public let imageURL: URL?
    public let trackCount: Int?
    public var lastPlayed: Date?

    public init(id: String, name: String, uri: String, imageURL: URL? = nil, trackCount: Int? = nil, lastPlayed: Date? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
        self.imageURL = imageURL
        self.trackCount = trackCount
        self.lastPlayed = lastPlayed
    }
}
