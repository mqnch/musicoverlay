import Foundation
import Combine

@MainActor
public class HUDViewModel: ObservableObject {

    // MARK: - Search

    @Published public var searchText: String = "" {
        didSet { onSearchTextChanged() }
    }
    @Published public var searchResults: [SearchResult] = []
    @Published public var isSearching: Bool = false

    // MARK: - Playlist drill-down

    @Published public var selectedPlaylist: Playlist? = nil
    @Published public var playlistTracks: [SpotifyTrack] = []
    @Published public var isLoadingTracks: Bool = false

    // MARK: - Keyboard selection

    @Published public var selectionIndex: Int = 0

    // MARK: - Playback state

    @Published public var isPlaying: Bool = false
    @Published public var isShuffled: Bool = false
    @Published public var repeatMode: RepeatMode = .off

    // MARK: - Slider state

    @Published public var playbackPosition: Double = 0   // seconds
    @Published public var trackDuration: Double = 1      // seconds (avoid /0)
    @Published public var volume: Double = 50            // 0–100
    @Published public var isSeeking: Bool = false        // true while user drags progress slider

    // MARK: - Internals

    private var stateController: StateController
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>? = nil
    private var cachedPlaylists: [Playlist] = []
    /// Timestamp of the last user-initiated play/pause toggle.
    /// We skip overwriting isPlaying from the timer for ~1.2s after a toggle
    /// so the optimistic UI state isn't immediately clobbered.
    private var lastToggleTime: Date = .distantPast

    public init(stateController: StateController) {
        self.stateController = stateController

        stateController.$activeService
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.prefetchPlaylists() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed

    public var displayedResults: [SearchResult] { searchResults }

    // MARK: - Search

    private func onSearchTextChanged() {
        selectionIndex = 0
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            searchResults = cachedPlaylists.map { .playlist($0) }
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await stateController.activeService?.search(query: query) ?? []
                guard !Task.isCancelled else { return }
                self.searchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                print("[HUDViewModel] Search error: \(error)")
                self.searchResults = []
            }
            self.isSearching = false
        }
    }

    private func prefetchPlaylists() async {
        guard let service = stateController.activeService else { return }
        do {
            let playlists = try await service.fetchPlaylists()
            cachedPlaylists = playlists
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = playlists.map { .playlist($0) }
            }
        } catch {
            print("[HUDViewModel] Failed to prefetch playlists: \(error)")
        }
    }

    // MARK: - Playlist drill-down

    public func openPlaylist(_ playlist: Playlist) {
        selectedPlaylist = playlist
        playlistTracks = []
        isLoadingTracks = true

        Task {
            do {
                let tracks = try await stateController.activeService?.fetchPlaylistTracks(playlistID: playlist.id) ?? []
                self.playlistTracks = tracks
                print("[HUDViewModel] Loaded \(tracks.count) tracks for playlist '\(playlist.name)'")
            } catch {
                print("[HUDViewModel] fetchPlaylistTracks error: \(error)")
                self.playlistTracks = []
            }
            self.isLoadingTracks = false
        }
    }

    public func closePlaylist() {
        selectedPlaylist = nil
        playlistTracks = []
    }

    // MARK: - Playback actions

    public func playResult(_ result: SearchResult) {
        switch result {
        case .track(let track):
            stateController.activeService?.playTrack(uri: track.uri)
            scheduleImmediateRefresh()
        case .playlist(let playlist):
            openPlaylist(playlist)
        }
    }

    public func playTrack(_ track: SpotifyTrack) {
        stateController.activeService?.playTrack(uri: track.uri)
        scheduleImmediateRefresh()
    }

    public func togglePlayPause() {
        if isPlaying {
            stateController.activeService?.pause()
        } else {
            stateController.activeService?.play()
        }
        isPlaying.toggle()
        lastToggleTime = Date()
    }

    public func nextTrack() {
        stateController.activeService?.next()
        scheduleImmediateRefresh()
    }

    public func previousTrack() {
        stateController.activeService?.previous()
        scheduleImmediateRefresh()
    }

    public func toggleShuffle() {
        isShuffled.toggle()
        stateController.activeService?.setShuffle(isShuffled)
    }

    public func cycleRepeat() {
        repeatMode = repeatMode.next()
        stateController.activeService?.setRepeat(repeatMode)
    }

    // MARK: - Volume & seeking

    public func commitVolume() {
        stateController.activeService?.setVolume(volume)
    }

    /// Adjusts volume by `delta` (e.g. ±5) and commits immediately.
    public func adjustVolume(_ delta: Double) {
        volume = max(0, min(100, volume + delta))
        stateController.activeService?.setVolume(volume)
    }

    public func commitSeek() {
        stateController.activeService?.seekTo(playbackPosition)
        isSeeking = false
    }

    // MARK: - Keyboard navigation

    public func moveSelectionUp() {
        if selectionIndex > 0 { selectionIndex -= 1 }
    }

    public func moveSelectionDown() {
        let max = displayedResults.count - 1
        if selectionIndex < max { selectionIndex += 1 }
    }

    public func activateSelection() {
        guard !displayedResults.isEmpty, selectionIndex < displayedResults.count else { return }
        playResult(displayedResults[selectionIndex])
    }

    // MARK: - Now Playing refresh (called by 0.5s timer)

    public func refreshNowPlaying() {
        guard let track = stateController.activeService?.getCurrentTrack() else {
            // Nothing playing — don't force isPlaying to any state
            return
        }
        stateController.currentTrack = track
        // Only sync isPlaying from AppleScript if we're not in the transient
        // window right after a user toggle (avoids flicker).
        let timeSinceToggle = Date().timeIntervalSince(lastToggleTime)
        if timeSinceToggle > 1.2 {
            isPlaying = track.isPlaying
        }
        // Only update sliders if user isn't actively dragging
        if !isSeeking {
            playbackPosition = track.position
        }
        if trackDuration != track.duration && track.duration > 0 {
            trackDuration = track.duration
        }
        volume = track.volume
    }

    /// Fire a refresh ~350ms after a track command so Spotify has time to switch.
    private func scheduleImmediateRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            refreshNowPlaying()
        }
    }
}
