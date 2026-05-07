import Foundation

public struct Playlist: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let uri: String
    
    public init(id: String, name: String, uri: String) {
        self.id = id
        self.name = name
        self.uri = uri
    }
}
