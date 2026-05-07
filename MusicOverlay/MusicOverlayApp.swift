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
                .onOpenURL { url in
                    SpotifyAuthManager.shared.handleCallbackURL(url)
                }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Foundation logic for accessory mode goes here
        // Set activation policy explicitly just to be safe
        NSApp.setActivationPolicy(.accessory)
    }
}
