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

    // MARK: - Keyboard selection (results list)

    @Published public var selectionIndex: Int = 0

    // MARK: - Playback controls state

    @Published public var isPlaying: Bool = false
    @Published public var isShuffled: Bool = false
    @Published public var repeatMode: RepeatMode = .off

    // MARK: - Internals

    private var stateController: StateController
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>? = nil
    private var cachedPlaylists: [Playlist] = []

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

    /// Current items displayed in the right panel (mixed).
    public var displayedResults: [SearchResult] {
        searchResults
    }

    // MARK: - Search

    private func onSearchTextChanged() {
        selectionIndex = 0
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            // Show cached playlists as playlist results when search is empty
            searchResults = cachedPlaylists.map { .playlist($0) }
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            // 300 ms debounce
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
            // Only populate results if the search bar is empty
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
            } catch {
                print("[HUDViewModel] Failed to load playlist tracks: \(error)")
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
        case .playlist(let playlist):
            openPlaylist(playlist)
        }
    }

    public func playTrack(_ track: SpotifyTrack) {
        stateController.activeService?.playTrack(uri: track.uri)
    }

    public func togglePlayPause() {
        if isPlaying {
            stateController.activeService?.pause()
        } else {
            stateController.activeService?.play()
        }
        isPlaying.toggle()
    }

    public func nextTrack() {
        stateController.activeService?.next()
    }

    public func previousTrack() {
        stateController.activeService?.previous()
    }

    public func toggleShuffle() {
        isShuffled.toggle()
        stateController.activeService?.setShuffle(isShuffled)
    }

    public func cycleRepeat() {
        repeatMode = repeatMode.next()
        stateController.activeService?.setRepeat(repeatMode)
    }

    // MARK: - Keyboard navigation (search results list)

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

    // MARK: - Track polling

    public func refreshNowPlaying() {
        if let track = stateController.activeService?.getCurrentTrack() {
            stateController.currentTrack = track
            isPlaying = true
        }
    }
}
