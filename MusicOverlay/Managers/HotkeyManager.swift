import AppKit
import Foundation

public class HotkeyManager {
    public static let shared = HotkeyManager()
    
    private var lastShiftPressTime: TimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    
    private init() {}
    
    public func setup() {
        // Clear existing monitors if any
        if let global = globalMonitor { NSEvent.removeMonitor(global) }
        if let local = localMonitor { NSEvent.removeMonitor(local) }
        
        let modifierName = UserDefaults.standard.string(forKey: "HUDViewModel.HotkeyModifier") ?? "Shift"
        let targetKeyCodes: [UInt16]
        let targetFlags: NSEvent.ModifierFlags
        
        switch modifierName {
        case "Control":
            targetKeyCodes = [59, 62]
            targetFlags = .control
        case "Option":
            targetKeyCodes = [58, 61]
            targetFlags = .option
        case "Command":
            targetKeyCodes = [55, 54]
            targetFlags = .command
        default: // Shift
            targetKeyCodes = [56, 60]
            targetFlags = .shift
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            
            if targetKeyCodes.contains(event.keyCode) {
                let isDown = event.modifierFlags.contains(targetFlags)
                
                if isDown {
                    let currentTime = Date().timeIntervalSince1970
                    let timeDiff = currentTime - self.lastShiftPressTime
                    
                    if timeDiff > 0.05 && timeDiff < 0.4 { // Double tap threshold
                        self.lastShiftPressTime = 0 // Reset
                        DispatchQueue.main.async {
                            if StateController.shared.onboardingCompleted {
                                WindowManager.shared.toggleHUD()
                            } else {
                                WindowManager.shared.showOnboardingWindow()
                            }
                        }
                    } else {
                        self.lastShiftPressTime = currentTime
                    }
                }
            }
        }
        
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
        
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
    }
}
