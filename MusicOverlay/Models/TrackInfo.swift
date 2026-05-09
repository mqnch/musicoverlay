import Foundation

public struct TrackInfo: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let albumArtURL: URL?
    public var position: TimeInterval   // current playback position in seconds
    public var volume: Double           // 0–100
    public var isPlaying: Bool          // actual player state from AppleScript
    public var isShuffled: Bool         // shuffle state
    public var repeatMode: RepeatMode   // repeat mode (off/context/track)

    public init(id: String, title: String, artist: String, album: String,
                duration: TimeInterval, albumArtURL: URL? = nil,
                position: TimeInterval = 0, volume: Double = 50,
                isPlaying: Bool = false, isShuffled: Bool = false,
                repeatMode: RepeatMode = .off) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.albumArtURL = albumArtURL
        self.position = position
        self.volume = volume
        self.isPlaying = isPlaying
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
    }
}
