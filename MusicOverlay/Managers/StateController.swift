import Foundation
import Combine
import SwiftUI

public class StateController: ObservableObject {
    public static let shared = StateController()
    
    @Published public var activeService: MediaServiceProtocol?
    @Published public var currentTrack: TrackInfo?
    @Published public var isPlaying: Bool = false
    
    @AppStorage("preferredService") public var preferredService: String = ""
    @AppStorage("onboardingCompleted") public var onboardingCompleted: Bool = false
    
    public init() {
        // Initialization happens in AppDelegate via initializeService()
    }
    
    public func setActiveService(_ service: MediaServiceProtocol) {
        self.activeService = service
    }
    
    public func initializeService() {
        if preferredService == "appleMusic" {
            setActiveService(AppleMusicManager())
        } else if preferredService == "spotify" {
            setActiveService(SpotifyManager())
        }
    }
}
