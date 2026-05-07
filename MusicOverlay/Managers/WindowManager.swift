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
        
        // Hide window when clicking outside (losing key status)
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            if panel.isVisible {
                panel.orderOut(nil)
            }
        }
        
        self.hudPanel = panel
    }
    
    public func toggleHUD() {
        guard let panel = hudPanel else { return }
        
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            // Ensures the window can receive keyboard events immediately
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
