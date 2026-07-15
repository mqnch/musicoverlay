import Foundation
import Combine
import AppKit

@MainActor
public class HUDViewModel: ObservableObject {

    // MARK: - Search

    @Published public var searchText: String = "" {
        didSet { onSearchTextChanged() }
    }
    @Published public var searchResults: [SearchResult] = []
    @Published public var isSearching: Bool = false
    @Published public var isMinimized: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var isMiniPlayerEnabled: Bool = true
    @Published public var showMenuBarIcon: Bool = true
    @Published public var hotkeyModifier: String = "Shift" // "Shift", "Control", "Option"
    @Published public var windowOpacity: Double = 1.0
    @Published public var uiScale: CGFloat = 1.0

    // MARK: - Playlist drill-down

    @Published public var selectedPlaylist: Playlist? = nil
    @Published public var playlistTracks: [SpotifyTrack] = []
    @Published public var isLoadingTracks: Bool = false
    @Published public var isLoadingMoreTracks: Bool = false
    @Published public var tracksHasMore: Bool = false

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

    /// Cached, possibly-partial track pages per playlist so reopening restores
    /// what was already loaded without refetching.
    private struct CachedTrackPage {
        var tracks: [SpotifyTrack]
        var offset: Int
        var hasMore: Bool
    }
    private var playlistTracksCache: [String: CachedTrackPage] = [:]

    /// How many tracks to load per page (Spotify caps each API call at 50, so
    /// this issues a few calls per page).
    private let trackPageSize = 200
    private var loadTracksTask: Task<Void, Never>? = nil
    
    private let lastPlayedKey = "HUDViewModel.LastPlayed"
    private let miniPlayerEnabledKey = "HUDViewModel.IsMiniPlayerEnabled"
    private let menuBarIconKey = "HUDViewModel.ShowMenuBarIcon"
    private let hotkeyModifierKey = "HUDViewModel.HotkeyModifier"
    private let windowOpacityKey = "HUDViewModel.WindowOpacity"
    private let uiScaleKey = "HUDViewModel.UIScale"
    private var lastPlayedDates: [String: Date] = [:]

    /// Timestamp of the last user-initiated play/pause toggle.
    private var lastToggleTime: Date = .distantPast

    public init(stateController: StateController) {
        self.stateController = stateController

        // Load persisted last played dates
        if let dict = UserDefaults.standard.dictionary(forKey: lastPlayedKey) as? [String: Date] {
            self.lastPlayedDates = dict
        }
        
        // Load settings
        if UserDefaults.standard.object(forKey: miniPlayerEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: miniPlayerEnabledKey)
        }
        self.isMiniPlayerEnabled = UserDefaults.standard.bool(forKey: miniPlayerEnabledKey)
        
        if UserDefaults.standard.object(forKey: menuBarIconKey) == nil {
            UserDefaults.standard.set(true, forKey: menuBarIconKey)
        }
        self.showMenuBarIcon = UserDefaults.standard.bool(forKey: menuBarIconKey)
        
        self.hotkeyModifier = UserDefaults.standard.string(forKey: hotkeyModifierKey) ?? "Shift"

        if UserDefaults.standard.object(forKey: windowOpacityKey) == nil {
            UserDefaults.standard.set(1.0, forKey: windowOpacityKey)
        }
        self.windowOpacity = UserDefaults.standard.double(forKey: windowOpacityKey)

        if UserDefaults.standard.object(forKey: uiScaleKey) == nil {
            UserDefaults.standard.set(1.0, forKey: uiScaleKey)
        }
        self.uiScale = CGFloat(UserDefaults.standard.double(forKey: uiScaleKey))

        stateController.$activeService
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Auto clear cache on service switch
                self?.clearCache()
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed

    public var displayedResults: [SearchResult] { searchResults }

    public var displayedPlaylistTracks: [SpotifyTrack] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return playlistTracks }
        return playlistTracks.filter { track in
            track.title.lowercased().contains(query) ||
            track.artist.lowercased().contains(query)
        }
    }

    // MARK: - Search

    private func onSearchTextChanged() {
        selectionIndex = 0
        
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()

        if query.isEmpty {
            searchResults = cachedPlaylists.map { .playlist($0) }
            isSearching = false
            return
        }

        // Local fuzzy search on playlists
        let filtered = cachedPlaylists.filter { playlist in
            playlist.name.lowercased().contains(query)
        }
        
        self.searchResults = filtered.map { .playlist($0) }
        self.isSearching = false
    }

    private func prefetchPlaylists() async {
        guard let service = stateController.activeService else { return }
        // Optimization: don't refetch if we already have them
        if !cachedPlaylists.isEmpty {
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = cachedPlaylists.map { .playlist($0) }
            }
            return
        }
        
        do {
            var playlists = try await service.fetchPlaylists()
            
            // Inject last played dates
            for i in 0..<playlists.count {
                playlists[i].lastPlayed = lastPlayedDates[playlists[i].id]
            }
            
            cachedPlaylists = playlists
            sortCachedPlaylists()
            
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = cachedPlaylists.map { .playlist($0) }
            }
        } catch {
            print("[HUDViewModel] Failed to prefetch playlists: \(error)")
        }
    }

    private func sortCachedPlaylists() {
        cachedPlaylists.sort { (p1, p2) -> Bool in
            // Pin Liked Songs to the very top.
            if p1.isLikedSongs != p2.isLikedSongs {
                return p1.isLikedSongs
            }
            let d1 = p1.lastPlayed ?? .distantPast
            let d2 = p2.lastPlayed ?? .distantPast
            if d1 != d2 {
                return d1 > d2 // Most recent first
            }
            return p1.name.localizedCompare(p2.name) == .orderedAscending
        }
    }

    private func markPlaylistPlayed(_ playlistID: String) {
        let now = Date()
        lastPlayedDates[playlistID] = now
        UserDefaults.standard.set(lastPlayedDates, forKey: lastPlayedKey)
        
        if let idx = cachedPlaylists.firstIndex(where: { $0.id == playlistID }) {
            cachedPlaylists[idx].lastPlayed = now
        }
        
        sortCachedPlaylists()
        
        // Refresh search if empty
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults = cachedPlaylists.map { .playlist($0) }
        }
    }

    // MARK: - Playlist drill-down

    public func openPlaylist(_ playlist: Playlist) {
        loadTracksTask?.cancel()
        selectedPlaylist = playlist
        selectionIndex = 0
        searchText = ""

        if let cached = playlistTracksCache[playlist.id] {
            playlistTracks = cached.tracks
            tracksHasMore = cached.hasMore
            isLoadingTracks = false
            isLoadingMoreTracks = false
            return
        }

        playlistTracks = []
        tracksHasMore = false
        isLoadingMoreTracks = false
        isLoadingTracks = true

        loadTracksTask = Task {
            do {
                let result = try await stateController.activeService?.fetchPlaylistTracks(
                    playlistID: playlist.id, offset: 0, limit: trackPageSize
                ) ?? (tracks: [], hasMore: false)
                if Task.isCancelled { return }
                self.playlistTracks = result.tracks
                self.tracksHasMore = result.hasMore
                self.playlistTracksCache[playlist.id] = CachedTrackPage(
                    tracks: result.tracks, offset: result.tracks.count, hasMore: result.hasMore
                )
                print("[HUDViewModel] Loaded \(result.tracks.count) tracks for playlist '\(playlist.name)' (hasMore=\(result.hasMore))")
            } catch {
                print("[HUDViewModel] fetchPlaylistTracks error: \(error)")
                self.playlistTracks = []
            }
            self.isLoadingTracks = false
        }
    }

    /// Loads the next page of tracks for the open playlist. Safe to call repeatedly;
    /// it no-ops while already loading or when there are no more tracks.
    public func loadMoreTracks() {
        guard let playlist = selectedPlaylist,
              tracksHasMore,
              !isLoadingTracks,
              !isLoadingMoreTracks else { return }

        isLoadingMoreTracks = true
        let offset = playlistTracks.count

        loadTracksTask = Task {	
            do {
                let result = try await stateController.activeService?.fetchPlaylistTracks(
                    playlistID: playlist.id, offset: offset, limit: trackPageSize
                ) ?? (tracks: [], hasMore: false)
                if Task.isCancelled { return }
                // Guard against the user having switched playlists mid-load.
                guard self.selectedPlaylist?.id == playlist.id else { return }
                self.playlistTracks.append(contentsOf: result.tracks)
                self.tracksHasMore = result.hasMore
                self.playlistTracksCache[playlist.id] = CachedTrackPage(
                    tracks: self.playlistTracks, offset: self.playlistTracks.count, hasMore: result.hasMore
                )
                print("[HUDViewModel] Loaded \(result.tracks.count) more tracks (total \(self.playlistTracks.count), hasMore=\(result.hasMore))")
            } catch {
                print("[HUDViewModel] loadMoreTracks error: \(error)")
            }
            self.isLoadingMoreTracks = false
        }
    }

    public func closePlaylist() {
        loadTracksTask?.cancel()
        selectedPlaylist = nil
        playlistTracks = []
        tracksHasMore = false
        isLoadingMoreTracks = false
        selectionIndex = 0
        searchText = ""
    }

    public func toggleSettings() {
        showSettings.toggle()
        if showSettings {
            selectedPlaylist = nil
            searchText = ""
        }
    }

    public func toggleMiniPlayer() {
        isMiniPlayerEnabled.toggle()
        UserDefaults.standard.set(isMiniPlayerEnabled, forKey: miniPlayerEnabledKey)
    }

    public func toggleMenuBarIcon() {
        showMenuBarIcon.toggle()
        UserDefaults.standard.set(showMenuBarIcon, forKey: menuBarIconKey)
        MenuBarManager.shared.setVisible(showMenuBarIcon)
    }

    public func updateHotkeyModifier(_ modifier: String) {
        hotkeyModifier = modifier
        UserDefaults.standard.set(modifier, forKey: hotkeyModifierKey)
        // Refresh the hotkey monitor
        HotkeyManager.shared.setup()
    }

    public func setWindowOpacity(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)   // 1.0 = full glass, 0.0 = solid opaque
        windowOpacity = clamped
        UserDefaults.standard.set(clamped, forKey: windowOpacityKey)
        WindowManager.shared.setWindowOpacity(clamped)
    }

    public func setUIScale(_ value: CGFloat) {
        let clamped = min(max(value, 0.8), 1.5)
        uiScale = clamped
        UserDefaults.standard.set(Double(clamped), forKey: uiScaleKey)
        WindowManager.shared.setUIScale(clamped)
    }

    public func clearCache() {
        cachedPlaylists = []
        playlistTracksCache = [:]
        Task { await prefetchPlaylists() }
    }

    public func logout() {
        // Clear all credentials and settings
        UserDefaults.standard.set(false, forKey: "onboardingCompleted")
        UserDefaults.standard.set("", forKey: "preferredService")
        
        KeychainHelper.shared.delete(service: "Spotify", account: "AccessToken")
        KeychainHelper.shared.delete(service: "Spotify", account: "RefreshToken")
        
        // Reset state controller
        stateController.onboardingCompleted = false
        stateController.activeService = nil
        
        // Hide HUD and show onboarding
        WindowManager.shared.actuallyHideHUD()
        WindowManager.shared.showOnboardingWindow()
    }

    public func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Playback actions

    public func playResult(_ result: SearchResult) {
        switch result {
        case .track(let track):
            stateController.activeService?.playTrack(uri: track.uri, contextUri: nil)
            scheduleImmediateRefresh()
            WindowManager.shared.hideHUD()
        case .playlist(let playlist):
            openPlaylist(playlist)
        }
    }

    public func playTrack(_ track: SpotifyTrack) {
        if let playlist = selectedPlaylist {
            markPlaylistPlayed(playlist.id)
        }

        if selectedPlaylist?.isLikedSongs == true,
           let index = playlistTracks.firstIndex(where: { $0.id == track.id }) {
            // Play Liked Songs as a real collection context so playback advances
            // (and honors shuffle) instead of looping the single track.
            stateController.activeService?.playLikedSongs(startIndex: index)
        } else {
            stateController.activeService?.playTrack(uri: track.uri, contextUri: selectedPlaylist?.uri)
        }
        scheduleImmediateRefresh()
        WindowManager.shared.hideHUD()
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
        lastToggleTime = Date()
    }

    public func cycleRepeat() {
        repeatMode = repeatMode.next()
        stateController.activeService?.setRepeat(repeatMode)
        lastToggleTime = Date()
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
        let count = selectedPlaylist != nil ? displayedPlaylistTracks.count : displayedResults.count
        if selectionIndex < count - 1 { selectionIndex += 1 }
    }
    
    public func activateSelection() {
        if let _ = selectedPlaylist {
            guard selectionIndex < displayedPlaylistTracks.count else { return }
            playTrack(displayedPlaylistTracks[selectionIndex])
        } else {
            guard !displayedResults.isEmpty, selectionIndex < displayedResults.count else { return }
            playResult(displayedResults[selectionIndex])
        }
    }

    // MARK: - Now Playing refresh (called by 0.5s timer)

    public func refreshNowPlaying() async {
        guard let service = stateController.activeService else { return }

        // Run the blocking AppleScript IPC off the main thread so the 0.5s poll
        // never stalls the UI. Resumes on the main actor after the await.
        let track = await Task.detached(priority: .utility) {
            service.getCurrentTrack()
        }.value

        guard let track else {
            // Nothing playing — don't force isPlaying to any state
            return
        }

        apply(track)
    }

    /// Applies a freshly-polled track to published state, only writing each
    /// property when it actually changed to avoid redundant SwiftUI rebuilds.
    private func apply(_ track: TrackInfo) {
        let current = stateController.currentTrack
        let isSameTrack = current?.title == track.title
            && current?.artist == track.artist
            && current?.album == track.album
            && current?.duration == track.duration
            && current?.albumArtURL == track.albumArtURL
        if !isSameTrack {
            stateController.currentTrack = track
        }

        // Only sync isPlaying from AppleScript if we're not in the transient
        // window right after a user toggle (avoids flicker).
        let timeSinceToggle = Date().timeIntervalSince(lastToggleTime)
        if timeSinceToggle > 1.2 {
            if isPlaying != track.isPlaying { isPlaying = track.isPlaying }
            if isShuffled != track.isShuffled { isShuffled = track.isShuffled }
            if repeatMode != track.repeatMode { repeatMode = track.repeatMode }
        }
        // Only update sliders if user isn't actively dragging
        if !isSeeking, playbackPosition != track.position {
            playbackPosition = track.position
        }
        if trackDuration != track.duration && track.duration > 0 {
            trackDuration = track.duration
        }
        if volume != track.volume { volume = track.volume }
    }

    /// Fire a refresh ~350ms after a track command so Spotify has time to switch.
    private func scheduleImmediateRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refreshNowPlaying()
        }
    }
}
