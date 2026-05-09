import SwiftUI
import AppKit

@main
struct MusicOverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // The app operates as an accessory/menu bar app (LSUIElement = true).
        // We use an empty Settings scene as a placeholder because we don't want
        // a standard window to appear on launch. The custom NSPanel will be
        // managed separately via the hotkey and WindowManager.
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        // Register for custom URL scheme events
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        
        // Setup Phase 5 Managers
        WindowManager.shared.setupHUD()
        HotkeyManager.shared.setup()
        
        if StateController.shared.onboardingCompleted {
            StateController.shared.initializeService()
        } else {
            WindowManager.shared.showOnboardingWindow()
        }
    }
    
    @objc func handleGetURLEvent(event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
           let url = URL(string: urlString) {
            SpotifyAuthManager.shared.handleCallbackURL(url)
        }
    }
}
