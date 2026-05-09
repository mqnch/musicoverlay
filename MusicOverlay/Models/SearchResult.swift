import Foundation

/// A union type representing a mixed search result from Spotify —
/// either a playable track or a browseable playlist.
public enum SearchResult: Identifiable {
    case track(SpotifyTrack)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case .track(let t):    return "track-\(t.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        }
    }
}

/// Repeat modes supported by the playback layer.
public enum RepeatMode: CaseIterable {
    case off
    case context   // repeat the whole playlist / album
    case track     // repeat the current track

    public func next() -> RepeatMode {
        switch self {
        case .off:     return .context
        case .context: return .track
        case .track:   return .off
        }
    }

    public var systemImage: String {
        switch self {
        case .off:     return "repeat"
        case .context: return "repeat"
        case .track:   return "repeat.1"
        }
    }

    public var isActive: Bool {
        self != .off
    }
}
