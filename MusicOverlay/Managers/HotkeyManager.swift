import AppKit
import Foundation

public class HotkeyManager {
    public static let shared = HotkeyManager()
    
    private var lastShiftPressTime: TimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    
    private init() {}
    
    public func setup() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            
            // KeyCode 56 is Left Shift, KeyCode 60 is Right Shift
            if event.keyCode == 56 || event.keyCode == 60 {
                let isShiftDown = event.modifierFlags.contains(.shift)
                
                if isShiftDown {
                    let currentTime = Date().timeIntervalSince1970
                    let timeDiff = currentTime - self.lastShiftPressTime
                    
                    if timeDiff > 0.05 && timeDiff < 0.4 { // Double tap threshold
                        self.lastShiftPressTime = 0 // Reset to prevent triple-tap firing twice
                        DispatchQueue.main.async {
                            WindowManager.shared.toggleHUD()
                        }
                    } else {
                        self.lastShiftPressTime = currentTime
                    }
                }
            }
        }
        
        // Local monitor (when app is active)
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
        
        // Global monitor (when app is in background)
        // Note: This requires Accessibility permissions in macOS System Settings!
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
    }
}
