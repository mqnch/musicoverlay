import Foundation
import Combine

public class StateController: ObservableObject {
    public static let shared = StateController()
    
    @Published public var activeService: MediaServiceProtocol?
    @Published public var currentTrack: TrackInfo?
    @Published public var isPlaying: Bool = false
    
    public init() {
        // Initialization will happen later when services are implemented
    }
    
    public func setActiveService(_ service: MediaServiceProtocol) {
        self.activeService = service
    }
}
