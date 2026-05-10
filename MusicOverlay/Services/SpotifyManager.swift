import Foundation

public class SpotifyManager: MediaServiceProtocol {

    public init() {}

    // MARK: - API Cache

    private var cachedPlaylists: [Playlist] = []
    private var cacheExpiration: Date = .distantPast

    // MARK: - Precompiled AppleScripts

    private let playScript  = NSAppleScript(source: "tell application \"Spotify\" to play")
    private let pauseScript = NSAppleScript(source: "tell application \"Spotify\" to pause")
    private let nextScript  = NSAppleScript(source: "tell application \"Spotify\" to next track")
    private let prevScript  = NSAppleScript(source: "tell application \"Spotify\" to previous track")

    /// Returns 8 pipe-delimited fields:
    /// title ||| artist ||| album ||| durationSec ||| artworkURL ||| playerPosition ||| soundVolume ||| playerState
    private let currentTrackScript = NSAppleScript(source: """
    tell application "Spotify"
        if player state is playing or player state is paused then
            set tId to id of current track
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDuration to duration of current track
            set tArt to artwork url of current track
            set tPos to player position
            set tVol to sound volume
            set tShuffle to shuffling
            set tRepeat to repeating
            if player state is playing then
                set tState to "playing"
            else
                set tState to "paused"
            end if
            return tId & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & (tDuration / 1000.0) & "|||" & tArt & "|||" & tPos & "|||" & tVol & "|||" & tState & "|||" & tShuffle & "|||" & tRepeat
        end if
        return ""
    end tell
    """)

    // MARK: - Script helpers

    private func executeCompiledScript(_ script: NSAppleScript?) -> String? {
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error)
        if let error = error {
            print("[SpotifyManager] AppleScript error: \(error)")
            return nil
        }
        return output?.stringValue
    }

    private func executeDynamicAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let output = script.executeAndReturnError(&error)
            if let error = error {
                print("[SpotifyManager] AppleScript error: \(error)")
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

    private func authorizedRequest(url: URL, method: String = "GET") -> URLRequest? {
        guard let token = accessToken() else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
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
        guard parts.count == 11 else {
            print("[SpotifyManager] getCurrentTrack: unexpected field count \(parts.count): \(result)")
            return nil
        }
        let trackId    = parts[0].trimmingCharacters(in: .whitespaces)
        let title      = parts[1].trimmingCharacters(in: .whitespaces)
        let artist     = parts[2].trimmingCharacters(in: .whitespaces)
        let album      = parts[3].trimmingCharacters(in: .whitespaces)
        let duration   = TimeInterval(parts[4].trimmingCharacters(in: .whitespaces)) ?? 0
        let artURLStr  = parts[5].trimmingCharacters(in: .whitespaces)
        let artURL     = artURLStr.isEmpty ? nil : URL(string: artURLStr)
        let position   = TimeInterval(parts[6].trimmingCharacters(in: .whitespaces)) ?? 0
        let volume     = Double(parts[7].trimmingCharacters(in: .whitespaces)) ?? 50
        let isPlaying  = parts[8].trimmingCharacters(in: .whitespaces) == "playing"
        let isShuffled = parts[9].trimmingCharacters(in: .whitespaces) == "true"
        let isRepeating = parts[10].trimmingCharacters(in: .whitespaces) == "true"

        return TrackInfo(
            id: trackId,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            albumArtURL: artURL,
            position: position,
            volume: volume,
            isPlaying: isPlaying,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? (lastSetRepeatMode == .track ? .track : .context) : .off
        )
    }

    // MARK: - MediaServiceProtocol — Playback commands

    public func playPlaylist(uri: String) {
        Task {
            await SpotifyAuthManager.shared.refreshTokenIfNeeded()
            guard let url = URL(string: "https://api.spotify.com/v1/me/player/play"),
                  var request = authorizedRequest(url: url, method: "PUT") else { return }
            
            let body: [String: Any] = ["context_uri": uri]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error { print("[SpotifyManager] playPlaylist error: \(error)") }
                else if let http = response as? HTTPURLResponse, http.statusCode != 204 {
                    print("[SpotifyManager] playPlaylist HTTP \(http.statusCode)")
                }
            }.resume()
        }
    }

    public func playTrack(uri: String, contextUri: String?) {
        Task {
            await SpotifyAuthManager.shared.refreshTokenIfNeeded()
            guard let url = URL(string: "https://api.spotify.com/v1/me/player/play"),
                  var request = authorizedRequest(url: url, method: "PUT") else { return }
            
            var body: [String: Any] = [:]
            if let context = contextUri {
                body["context_uri"] = context
                body["offset"] = ["uri": uri]
            } else {
                body["uris"] = [uri]
            }
            
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error { print("[SpotifyManager] playTrack error: \(error)") }
                else if let http = response as? HTTPURLResponse, http.statusCode != 204 {
                    print("[SpotifyManager] playTrack HTTP \(http.statusCode)")
                }
            }.resume()
        }
    }

    public func setShuffle(_ on: Bool) {
        _ = executeDynamicAppleScript("tell application \"Spotify\" to set shuffling to \(on ? "true" : "false")")
    }

    /// Precise repeat state (off / context / track) as AppleScript only provides boolean.
    private var lastSetRepeatMode: RepeatMode = .off

    public func setRepeat(_ mode: RepeatMode) {
        lastSetRepeatMode = mode
        
        // AppleScript: boolean on/off
        let boolVal = mode.isActive ? "true" : "false"
        _ = executeDynamicAppleScript("tell application \"Spotify\" to set repeating to \(boolVal)")

        // Web API: precise 3-state (requires user-modify-playback-state scope)
        let state: String
        switch mode {
        case .off:     state = "off"
        case .context: state = "context"
        case .track:   state = "track"
        }

        Task {
            await SpotifyAuthManager.shared.refreshTokenIfNeeded()
            guard let url = URL(string: "https://api.spotify.com/v1/me/player/repeat?state=\(state)"),
                  let request = authorizedRequest(url: url, method: "PUT") else { return }

            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error {
                    print("[SpotifyManager] setRepeat API error: \(error)")
                } else if let http = response as? HTTPURLResponse {
                    print("[SpotifyManager] setRepeat API status: \(http.statusCode)")
                }
            }.resume()
        }
    }

    // MARK: - MediaServiceProtocol — Volume & seeking

    public func setVolume(_ volume: Double) {
        let clamped = Int(max(0, min(100, volume)))
        _ = executeDynamicAppleScript("tell application \"Spotify\" to set sound volume to \(clamped)")
    }

    public func seekTo(_ position: TimeInterval) {
        _ = executeDynamicAppleScript("tell application \"Spotify\" to set player position to \(position)")
    }

    // MARK: - MediaServiceProtocol — Playlist fetching

    public func fetchPlaylists() async throws -> [Playlist] {
        if Date() < cacheExpiration && !cachedPlaylists.isEmpty {
            return cachedPlaylists
        }

        await SpotifyAuthManager.shared.refreshTokenIfNeeded()

        var allPlaylists: [Playlist] = []
        var nextURL: URL? = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")

        while let url = nextURL {
            guard let request = authorizedRequest(url: url) else { break }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8)?.prefix(300) ?? "(unreadable)"
                print("[SpotifyManager] fetchPlaylists HTTP \(http.statusCode): \(body)")
                break
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { break }

            let pagePlaylists: [Playlist] = items.compactMap { item in
                guard let id   = item["id"]   as? String,
                      let name = item["name"] as? String,
                      let uri  = item["uri"]  as? String else { return nil }

                let imageURL: URL? = {
                    if let images = item["images"] as? [[String: Any]],
                       let first = images.first,
                       let urlStr = first["url"] as? String { return URL(string: urlStr) }
                    return nil
                }()

                let trackCount: Int? = (item["tracks"] as? [String: Any])?["total"] as? Int
                return Playlist(id: id, name: name, uri: uri, imageURL: imageURL, trackCount: trackCount)
            }
            allPlaylists.append(contentsOf: pagePlaylists)

            if let next = json["next"] as? String, let nextU = URL(string: next) {
                nextURL = nextU
            } else {
                nextURL = nil
            }
        }

        cachedPlaylists = allPlaylists
        cacheExpiration = Date().addingTimeInterval(300)
        return allPlaylists
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

        await SpotifyAuthManager.shared.refreshTokenIfNeeded()

        guard let url = components.url,
              let request = authorizedRequest(url: url) else { return [] }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? "(unreadable)"
            print("[SpotifyManager] search HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body)")
            return []
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var results: [SearchResult] = []

        if let tracksObj = json["tracks"] as? [String: Any],
           let trackItems = tracksObj["items"] as? [[String: Any]] {
            for item in trackItems {
                guard let id   = item["id"]   as? String,
                      let name = item["name"] as? String,
                      let uri  = item["uri"]  as? String else { continue }

                let artist: String = {
                    if let artists = item["artists"] as? [[String: Any]],
                       let first = artists.first,
                       let n = first["name"] as? String { return n }
                    return "Unknown Artist"
                }()

                let album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
                let albumArtURL: URL? = {
                    if let albumObj = item["album"] as? [String: Any],
                       let images = albumObj["images"] as? [[String: Any]],
                       let last = images.last,
                       let urlStr = last["url"] as? String { return URL(string: urlStr) }
                    return nil
                }()

                let durationMs = item["duration_ms"] as? Int ?? 0
                results.append(.track(SpotifyTrack(id: id, title: name, artist: artist,
                                                    album: album, uri: uri,
                                                    albumArtURL: albumArtURL, durationMs: durationMs)))
            }
        }

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
        // Refresh token if expired before making any API calls
        await SpotifyAuthManager.shared.refreshTokenIfNeeded()

        var allTracks: [SpotifyTrack] = []
        var nextURL: URL? = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/items?limit=50")

        while let url = nextURL {
            guard let request = authorizedRequest(url: url) else {
                print("[SpotifyManager] fetchPlaylistTracks: no access token")
                break
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { break }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8)?.prefix(400) ?? "(unreadable)"
                print("[SpotifyManager] fetchPlaylistTracks HTTP \(http.statusCode): \(body)")
                break
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }

            if let items = json["items"] as? [[String: Any]] {
                for item in items {
                    guard let trackObj = item["item"] as? [String: Any] else { continue }
                    
                    let type = trackObj["type"] as? String ?? "unknown"
                    if type != "track" { continue }

                    guard let id   = trackObj["id"]   as? String,
                          let name = trackObj["name"] as? String,
                          let uri  = trackObj["uri"]  as? String else { continue }

                    let artist: String = {
                        if let artists = trackObj["artists"] as? [[String: Any]],
                           let first = artists.first,
                           let n = first["name"] as? String { return n }
                        return "Unknown Artist"
                    }()

                    let album = (trackObj["album"] as? [String: Any])?["name"] as? String ?? ""
                    let albumArtURL: URL? = {
                        if let albumObj = trackObj["album"] as? [String: Any],
                           let images = albumObj["images"] as? [[String: Any]],
                           let last = images.last,
                           let urlStr = last["url"] as? String { return URL(string: urlStr) }
                        return nil
                    }()

                    let durationMs = trackObj["duration_ms"] as? Int ?? 0
                    allTracks.append(SpotifyTrack(id: id, title: name, artist: artist,
                                                   album: album, uri: uri,
                                                   albumArtURL: albumArtURL, durationMs: durationMs))
                }
                print("[SpotifyManager] fetchPlaylistTracks: loaded \(allTracks.count) tracks so far")
            }

            if let next = json["next"] as? String, let nextU = URL(string: next) {
                nextURL = nextU
            } else {
                nextURL = nil
            }
        }

        return allTracks
    }
}
