import AppKit
import SwiftUI

public class WindowManager {
    public static let shared = WindowManager()
    
    private var hudPanel: NSPanel?
    
    private init() {}
    
    public func setupHUD() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Ensures the window floats over fullscreen apps and joins all spaces
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.center()
        
        // Setup hardware-accelerated background blur
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16.0
        visualEffect.layer?.masksToBounds = true
        
        // Setup HUD View
        let hudView = HUDView(stateController: StateController.shared)
            .environmentObject(StateController.shared)
        let hostingView = NSHostingView(rootView: hudView)
        visualEffect.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])
        
        panel.contentView = visualEffect
        
        // Hide window when the app loses focus (clicking outside)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            WindowManager.shared.hideHUD()
        }
        
        // Intercept Escape key to close the HUD reliably
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // 53 is the Escape key
                if WindowManager.shared.hudPanel?.isVisible == true {
                    WindowManager.shared.hideHUD()
                    return nil // Consume the event
                }
            }
            return event
        }
        
        self.hudPanel = panel
    }
    
    public func toggleHUD() {
        guard let panel = hudPanel else { return }
        
        if panel.isVisible {
            hideHUD()
        } else {
            showHUD()
        }
    }
    
    public func showHUD() {
        guard let panel = hudPanel else { return }
        
        panel.alphaValue = 0.0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
    }
    
    public func hideHUD() {
        guard let panel = hudPanel, panel.isVisible else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
