import Foundation

public class SpotifyManager: MediaServiceProtocol {

    public init() {}

    // MARK: - API Cache

    private var cachedPlaylists: [Playlist] = []
    private var cacheExpiration: Date = .distantPast

    // MARK: - Precompiled AppleScripts

    private let playScript    = NSAppleScript(source: "tell application \"Spotify\" to play")
    private let pauseScript   = NSAppleScript(source: "tell application \"Spotify\" to pause")
    private let nextScript    = NSAppleScript(source: "tell application \"Spotify\" to next track")
    private let prevScript    = NSAppleScript(source: "tell application \"Spotify\" to previous track")

    private let currentTrackScript = NSAppleScript(source: """
    tell application "Spotify"
        if player state is playing then
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDuration to duration of current track
            return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & (tDuration / 1000.0)
        end if
        return ""
    end tell
    """)

    // MARK: - Script helpers

    private func executeCompiledScript(_ script: NSAppleScript?) -> String? {
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error)
        if let error = error {
            print("Spotify AppleScript Error: \(error)")
            return nil
        }
        return output?.stringValue
    }

    private func executeDynamicAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let output = script.executeAndReturnError(&error)
            if let error = error {
                print("Spotify AppleScript Error: \(error)")
                return nil
            }
            return output.stringValue
        }
        return nil
    }

    // MARK: - Token helper

    private func accessToken() -> String? {
        guard let data = KeychainHelper.shared.read(service: "Spotify", account: "AccessToken"),
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    private func authorizedRequest(url: URL) -> URLRequest? {
        guard let token = accessToken() else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - MediaServiceProtocol — Basic playback

    public func play() {
        _ = executeCompiledScript(playScript)
    }

    public func pause() {
        _ = executeCompiledScript(pauseScript)
    }

    public func next() {
        _ = executeCompiledScript(nextScript)
    }

    public func previous() {
        _ = executeCompiledScript(prevScript)
    }

    public func getCurrentTrack() -> TrackInfo? {
        guard let result = executeCompiledScript(currentTrackScript), !result.isEmpty else { return nil }
        let parts = result.components(separatedBy: "|||")
        guard parts.count == 4 else { return nil }
        let duration = TimeInterval(parts[3]) ?? 0.0
        return TrackInfo(id: UUID().uuidString, title: parts[0], artist: parts[1],
                         album: parts[2], duration: duration, albumArtURL: nil)
    }

    // MARK: - MediaServiceProtocol — Playback commands

    public func playPlaylist(uri: String) {
        _ = executeDynamicAppleScript("tell application \"Spotify\" to play track \"\(uri)\"")
    }

    public func playTrack(uri: String) {
        _ = executeDynamicAppleScript("tell application \"Spotify\" to play track \"\(uri)\"")
    }

    public func setShuffle(_ on: Bool) {
        let value = on ? "true" : "false"
        _ = executeDynamicAppleScript("tell application \"Spotify\" to set shuffling to \(value)")
    }

    public func setRepeat(_ mode: RepeatMode) {
        // Spotify AppleScript only has on/off for repeating
        let value = mode.isActive ? "true" : "false"
        _ = executeDynamicAppleScript("tell application \"Spotify\" to set repeating to \(value)")
    }

    // MARK: - MediaServiceProtocol — Playlist fetching

    public func fetchPlaylists() async throws -> [Playlist] {
        if Date() < cacheExpiration && !cachedPlaylists.isEmpty {
            return cachedPlaylists
        }

        guard let url = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50"),
              let request = authorizedRequest(url: url) else { return [] }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }

        let playlists: [Playlist] = items.compactMap { item in
            guard let id   = item["id"]   as? String,
                  let name = item["name"] as? String,
                  let uri  = item["uri"]  as? String else { return nil }

            // Parse first image URL
            let imageURL: URL? = {
                if let images = item["images"] as? [[String: Any]],
                   let first = images.first,
                   let urlStr = first["url"] as? String {
                    return URL(string: urlStr)
                }
                return nil
            }()

            // Track count
            let trackCount: Int? = (item["tracks"] as? [String: Any])?["total"] as? Int

            return Playlist(id: id, name: name, uri: uri, imageURL: imageURL, trackCount: trackCount)
        }

        cachedPlaylists = playlists
        cacheExpiration = Date().addingTimeInterval(300)
        return playlists
    }

    // MARK: - MediaServiceProtocol — Search

    public func search(query: String) async throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q",     value: query),
            URLQueryItem(name: "type",  value: "track,playlist"),
            URLQueryItem(name: "limit", value: "8")
        ]

        guard let url = components.url,
              let request = authorizedRequest(url: url) else { return [] }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var results: [SearchResult] = []

        // Parse tracks
        if let tracksObj = json["tracks"] as? [String: Any],
           let trackItems = tracksObj["items"] as? [[String: Any]] {
            for item in trackItems {
                guard let id   = item["id"]   as? String,
                      let name = item["name"] as? String,
                      let uri  = item["uri"]  as? String else { continue }

                let artist: String = {
                    if let artists = item["artists"] as? [[String: Any]],
                       let first = artists.first,
                       let artistName = first["name"] as? String { return artistName }
                    return "Unknown Artist"
                }()

                let album: String = (item["album"] as? [String: Any])?["name"] as? String ?? ""

                let albumArtURL: URL? = {
                    if let albumObj = item["album"] as? [String: Any],
                       let images = albumObj["images"] as? [[String: Any]],
                       let last = images.last,           // smallest image
                       let urlStr = last["url"] as? String {
                        return URL(string: urlStr)
                    }
                    return nil
                }()

                let durationMs = item["duration_ms"] as? Int ?? 0

                let track = SpotifyTrack(id: id, title: name, artist: artist, album: album,
                                         uri: uri, albumArtURL: albumArtURL, durationMs: durationMs)
                results.append(.track(track))
            }
        }

        // Parse playlists
        if let playlistsObj = json["playlists"] as? [String: Any],
           let playlistItems = playlistsObj["items"] as? [[String: Any]] {
            for item in playlistItems {
                guard let id   = item["id"]   as? String,
                      let name = item["name"] as? String,
                      let uri  = item["uri"]  as? String else { continue }

                let imageURL: URL? = {
                    if let images = item["images"] as? [[String: Any]],
                       let first = images.first,
                       let urlStr = first["url"] as? String { return URL(string: urlStr) }
                    return nil
                }()

                let trackCount: Int? = (item["tracks"] as? [String: Any])?["total"] as? Int
                results.append(.playlist(Playlist(id: id, name: name, uri: uri,
                                                   imageURL: imageURL, trackCount: trackCount)))
            }
        }

        return results
    }

    // MARK: - MediaServiceProtocol — Playlist tracks

    public func fetchPlaylistTracks(playlistID: String) async throws -> [SpotifyTrack] {
        var allTracks: [SpotifyTrack] = []
        var nextURL: URL? = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/tracks?limit=50&fields=next,items(track(id,name,uri,duration_ms,artists,album(name,images)))")

        while let url = nextURL {
            guard let request = authorizedRequest(url: url) else { break }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { break }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }

            if let items = json["items"] as? [[String: Any]] {
                for item in items {
                    guard let trackObj = item["track"] as? [String: Any],
                          let id   = trackObj["id"]   as? String,
                          let name = trackObj["name"] as? String,
                          let uri  = trackObj["uri"]  as? String else { continue }

                    let artist: String = {
                        if let artists = trackObj["artists"] as? [[String: Any]],
                           let first = artists.first,
                           let n = first["name"] as? String { return n }
                        return "Unknown Artist"
                    }()

                    let album: String = (trackObj["album"] as? [String: Any])?["name"] as? String ?? ""

                    let albumArtURL: URL? = {
                        if let albumObj = trackObj["album"] as? [String: Any],
                           let images = albumObj["images"] as? [[String: Any]],
                           let last = images.last,
                           let urlStr = last["url"] as? String { return URL(string: urlStr) }
                        return nil
                    }()

                    let durationMs = trackObj["duration_ms"] as? Int ?? 0
                    allTracks.append(SpotifyTrack(id: id, title: name, artist: artist, album: album,
                                                   uri: uri, albumArtURL: albumArtURL, durationMs: durationMs))
                }
            }

            // Pagination
            if let next = json["next"] as? String, let nextU = URL(string: next) {
                nextURL = nextU
            } else {
                nextURL = nil
            }
        }

        return allTracks
    }
}
