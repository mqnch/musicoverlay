import Foundation
import Combine

@MainActor
public class HUDViewModel: ObservableObject {
    @Published public var searchText: String = "" {
        didSet {
            selectionIndex = 0
        }
    }
    @Published public var cachedPlaylists: [Playlist] = []
    @Published public var selectionIndex: Int = 0
    
    private var stateController: StateController
    private var cancellables = Set<AnyCancellable>()
    
    public init(stateController: StateController) {
        self.stateController = stateController
        
        stateController.$activeService
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.fetchPlaylists()
                }
            }
            .store(in: &cancellables)
    }
    
    public var filteredPlaylists: [Playlist] {
        if searchText.isEmpty {
            return cachedPlaylists
        }
        return cachedPlaylists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    public func fetchPlaylists() async {
        guard let service = stateController.activeService else { return }
        do {
            let playlists = try await service.fetchPlaylists()
            self.cachedPlaylists = playlists
        } catch {
            print("Failed to fetch playlists: \\(error)")
        }
    }
    
    public func moveSelectionUp() {
        if selectionIndex > 0 {
            selectionIndex -= 1
        }
    }
    
    public func moveSelectionDown() {
        if selectionIndex < filteredPlaylists.count - 1 {
            selectionIndex += 1
        }
    }
    
    public func playSelected() {
        guard !filteredPlaylists.isEmpty, selectionIndex < filteredPlaylists.count else { return }
        let selectedPlaylist = filteredPlaylists[selectionIndex]
        stateController.activeService?.playPlaylist(uri: selectedPlaylist.uri)
    }
}
