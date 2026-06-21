import AppKit

public class SpotifyManager: MediaServiceProtocol {
    public var name: String { "Spotify" }

    public init() {}

    // MARK: - API Cache

    private var cachedPlaylists: [Playlist] = []
    private var cacheExpiration: Date = .distantPast

    // MARK: - AppleScript sources

    private let playSource  = "tell application \"Spotify\" to play"
    private let pauseSource = "tell application \"Spotify\" to pause"
    private let nextSource  = "tell application \"Spotify\" to next track"
    private let prevSource  = "tell application \"Spotify\" to previous track"

    /// Returns 8 pipe-delimited fields:
    /// title ||| artist ||| album ||| durationSec ||| artworkURL ||| playerPosition ||| soundVolume ||| playerState
    private let currentTrackSource = """
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
    """

    // MARK: - Script execution

    /// Dedicated serial queue for all AppleScript work so the blocking Apple
    /// Events IPC never runs on the main thread and `NSAppleScript` instances are
    /// only ever touched from one consistent thread.
    private let scriptQueue = DispatchQueue(label: "com.musicoverlay.spotify.applescript")

    /// Compiled scripts cache. MUST only be accessed from `scriptQueue`.
    private var compiledScripts: [String: NSAppleScript] = [:]

    private func isSpotifyRunning() -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    /// Compiles (and caches) the script for `source`, then executes it. All work
    /// runs synchronously on `scriptQueue`, so callers should invoke this from a
    /// background thread to avoid blocking the main thread.
    @discardableResult
    private func runScript(_ source: String, cache: Bool = true) -> String? {
        return scriptQueue.sync {
            guard isSpotifyRunning() else { return nil }

            let script: NSAppleScript
            if cache, let cached = compiledScripts[source] {
                script = cached
            } else {
                guard let compiled = NSAppleScript(source: source) else { return nil }
                if cache { compiledScripts[source] = compiled }
                script = compiled
            }

            var error: NSDictionary?
            let output = script.executeAndReturnError(&error)
            if let error = error {
                print("[SpotifyManager] AppleScript error: \(error)")
                return nil
            }
            return output.stringValue
        }
    }

    // MARK: - Token helper

    private func accessToken() -> String? {
        guard let data = KeychainHelper.shared.read(service: "Spotify", account: "AccessToken"),
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    private var cachedUserID: String?

    /// Fetches and caches the current Spotify user ID (needed to build the
    /// Liked Songs collection context URI `spotify:user:{id}:collection`).
    private func currentUserID() async -> String? {
        if let id = cachedUserID { return id }
        guard let url = URL(string: "https://api.spotify.com/v1/me"),
              let request = authorizedRequest(url: url) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { return nil }
        cachedUserID = id
        return id
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
        runScript(playSource)
    }

    public func pause() {
        runScript(pauseSource)
    }

    public func next() {
        runScript(nextSource)
    }

    public func previous() {
        runScript(prevSource)
    }

    public func getCurrentTrack() -> TrackInfo? {
        guard let result = runScript(currentTrackSource), !result.isEmpty else { return nil }
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
            do {
                let offset: [String: Any]? = contextUri != nil ? ["uri": uri] : nil
                try await performPlay(uri: uri, contextUri: contextUri, offset: offset, retryWithTransfer: true)
            } catch {
                print("[SpotifyManager] playTrack failed: \(error)")
            }
        }
    }

    /// Plays the user's Liked Songs as a real context starting at `startIndex`,
    /// so Spotify advances through the collection (respecting shuffle) instead
    /// of looping a single track.
    public func playLikedSongs(startIndex: Int) {
        Task {
            await SpotifyAuthManager.shared.refreshTokenIfNeeded()
            guard let uid = await currentUserID() else {
                print("[SpotifyManager] playLikedSongs: could not resolve user ID")
                return
            }
            let contextUri = "spotify:user:\(uid):collection"
            do {
                try await performPlay(uri: nil,
                                      contextUri: contextUri,
                                      offset: ["position": startIndex],
                                      retryWithTransfer: true)
            } catch {
                print("[SpotifyManager] playLikedSongs failed: \(error)")
            }
        }
    }

    private func performPlay(uri: String?, contextUri: String?, offset: [String: Any]?, retryWithTransfer: Bool) async throws {
        guard let url = URL(string: "https://api.spotify.com/v1/me/player/play"),
              var request = authorizedRequest(url: url, method: "PUT") else { return }
        
        var body: [String: Any] = [:]
        if let context = contextUri {
            body["context_uri"] = context
            if let offset = offset { body["offset"] = offset }
        } else if let uri = uri {
            body["uris"] = [uri]
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        
        if http.statusCode == 404 && retryWithTransfer {
            print("[SpotifyManager] playTrack 404 (No active device). Attempting to transfer playback...")
            if await transferPlaybackToAvailableDevice() {
                // Wait briefly for transfer to propagate
                try? await Task.sleep(nanoseconds: 500_000_000)
                try await performPlay(uri: uri, contextUri: contextUri, offset: offset, retryWithTransfer: false)
            } else {
                print("[SpotifyManager] No available devices for transfer. Falling back to AppleScript.")
                if let uri = uri { playURIViaAppleScript(uri: uri, contextUri: contextUri) }
            }
        } else if http.statusCode != 204 && http.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            print("[SpotifyManager] playTrack HTTP \(http.statusCode): \(errorBody)")
            // If all Web API attempts fail, try AppleScript as a final effort
            if retryWithTransfer, let uri = uri {
                playURIViaAppleScript(uri: uri, contextUri: contextUri)
            }
        }
    }

    private func transferPlaybackToAvailableDevice() async -> Bool {
        guard let url = URL(string: "https://api.spotify.com/v1/me/player/devices"),
              let request = authorizedRequest(url: url) else { return false }
        
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]],
              let deviceId = (devices.first(where: { ($0["is_active"] as? Bool) == true }) ?? devices.first)?["id"] as? String else { 
            return false 
        }
        
        guard let transferURL = URL(string: "https://api.spotify.com/v1/me/player"),
              var transferReq = authorizedRequest(url: transferURL, method: "PUT") else { return false }
        
        let body: [String: Any] = ["device_ids": [deviceId], "play": false]
        transferReq.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (_, transferRes) = (try? await URLSession.shared.data(for: transferReq)) ?? (Data(), URLResponse())
        return (transferRes as? HTTPURLResponse)?.statusCode == 204
    }

    private func playURIViaAppleScript(uri: String, contextUri: String?) {
        let script: String
        if let context = contextUri {
            // Using 'in context' ensures it plays within the playlist/album context
            script = "tell application \"Spotify\" to play track \"\(uri)\" in context \"\(context)\""
        } else {
            script = "tell application \"Spotify\" to play track \"\(uri)\""
        }
        runScript(script, cache: false)
    }

    public func setShuffle(_ on: Bool) {
        runScript("tell application \"Spotify\" to set shuffling to \(on ? "true" : "false")", cache: false)
    }

    /// Precise repeat state (off / context / track) as AppleScript only provides boolean.
    private var lastSetRepeatMode: RepeatMode = .off

    public func setRepeat(_ mode: RepeatMode) {
        lastSetRepeatMode = mode
        
        // AppleScript: boolean on/off
        let boolVal = mode.isActive ? "true" : "false"
        runScript("tell application \"Spotify\" to set repeating to \(boolVal)", cache: false)

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
        runScript("tell application \"Spotify\" to set sound volume to \(clamped)", cache: false)
    }

    public func seekTo(_ position: TimeInterval) {
        runScript("tell application \"Spotify\" to set player position to \(position)", cache: false)
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

        // Prepend the synthetic "Liked Songs" pseudo-playlist at the top.
        let likedTotal = try? await fetchLikedSongsTotal()
        let likedSongs = Playlist(id: Playlist.likedSongsID,
                                  name: "Liked Songs",
                                  uri: "",
                                  imageURL: nil,
                                  trackCount: likedTotal)
        allPlaylists.insert(likedSongs, at: 0)

        cachedPlaylists = allPlaylists
        cacheExpiration = Date().addingTimeInterval(300)
        return allPlaylists
    }

    /// Lightweight call to read the total number of saved (liked) tracks.
    private func fetchLikedSongsTotal() async throws -> Int? {
        guard let url = URL(string: "https://api.spotify.com/v1/me/tracks?limit=1"),
              let request = authorizedRequest(url: url) else { return nil }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["total"] as? Int
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

    /// Spotify's per-request maximum for the playlist-items / saved-tracks endpoints.
    private static let apiPageSize = 50

    /// Fetches a window of `limit` tracks starting at `offset`. Internally issues
    /// as many 50-item API calls as needed to fill the window, so the UI can load
    /// large playlists in pages instead of all at once.
    public func fetchPlaylistTracks(playlistID: String, offset: Int, limit: Int) async throws -> (tracks: [SpotifyTrack], hasMore: Bool) {
        await SpotifyAuthManager.shared.refreshTokenIfNeeded()

        let isLikedSongs = playlistID == Playlist.likedSongsID
        let base = isLikedSongs
            ? "https://api.spotify.com/v1/me/tracks"
            : "https://api.spotify.com/v1/playlists/\(playlistID)/items"

        var collected: [SpotifyTrack] = []
        var currentOffset = offset
        var total = Int.max

        while collected.count < limit {
            let pageLimit = min(SpotifyManager.apiPageSize, limit - collected.count)

            guard var components = URLComponents(string: base) else { break }
            components.queryItems = [
                URLQueryItem(name: "limit",  value: "\(pageLimit)"),
                URLQueryItem(name: "offset", value: "\(currentOffset)")
            ]
            guard let url = components.url, let request = authorizedRequest(url: url) else {
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

            total = json["total"] as? Int ?? total
            let items = json["items"] as? [[String: Any]] ?? []
            if items.isEmpty { break }

            for item in items {
                // Saved-tracks use the "track" key; playlist items use "item" here.
                guard let trackObj = (item["item"] as? [String: Any]) ?? (item["track"] as? [String: Any]),
                      let track = parseTrack(trackObj) else { continue }
                collected.append(track)
            }

            currentOffset += items.count
            // Reached the end of the collection.
            if items.count < pageLimit { break }
        }

        let hasMore = currentOffset < total
        print("[SpotifyManager] fetchPlaylistTracks: loaded \(collected.count) (offset \(offset)), hasMore=\(hasMore)")
        return (collected, hasMore)
    }

    /// Parses a single Spotify track/episode JSON object into a `SpotifyTrack`.
    private func parseTrack(_ trackObj: [String: Any]) -> SpotifyTrack? {
        let type = trackObj["type"] as? String ?? "unknown"
        if type != "track" && type != "episode" { return nil }

        guard let id   = trackObj["id"]   as? String,
              let name = trackObj["name"] as? String,
              let uri  = trackObj["uri"]  as? String else { return nil }

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
        return SpotifyTrack(id: id, title: name, artist: artist,
                            album: album, uri: uri,
                            albumArtURL: albumArtURL, durationMs: durationMs)
    }
}
