import AppKit
import SwiftUI

public class HUDPanel: NSPanel {
    public override var canBecomeKey: Bool {
        return true
    }
}

public class WindowManager {
    public static let shared = WindowManager()
    
    private var hudPanel: NSPanel?
    private var onboardingWindow: NSWindow?
    private var keyboardMonitor: Any?
    
    // Double-tap state
    private var lastKeyPressTime: Date = .distantPast
    private var lastKeyCode: UInt16 = 0
    private var pendingAction: DispatchWorkItem?

    /// Registered by HUDView so the keyboard monitor can route commands.
    public weak var activeViewModel: HUDViewModel?
    
    private init() {}
    
    public func setupHUD() {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Allows the panel to become the key window so text fields work
        panel.becomesKeyOnlyIfNeeded = false
        // Ensures the window floats over fullscreen apps and joins all spaces
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.center()
        
        // Setup hardware-accelerated background blur (Liquid Glass)
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .vibrantDark)
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 24.0
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        
        // Apply mask to fix "ghost corners" where vibrancy renders outside rounded borders
        visualEffect.maskImage = .maskImage(cornerRadius: 24.0, size: panel.contentRect(forFrameRect: panel.frame).size)
        
        // Setup HUD View
        let hudView = HUDView(stateController: StateController.shared)
            .environmentObject(StateController.shared)
            .fontDesign(.monospaced)
        let hostingView = NSHostingView(rootView: hudView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        
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
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            WindowManager.shared.hideHUD()
        }
        
        // Intercept Escape key to close the HUD reliably
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.hudPanel?.isVisible == true else { return event }

            // Escape — close HUD
            if event.keyCode == 53 {
                self.hideHUD()
                return nil
            }

            guard let vm = self.activeViewModel else { return event }
            let hasModifiers = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty

            if !hasModifiers {
                switch event.keyCode {
                case 49: // Space bar — toggle play/pause
                    DispatchQueue.main.async { vm.togglePlayPause() }
                    return nil

                case 124: // Right arrow
                    let now = Date()
                    if lastKeyCode == 124 && now.timeIntervalSince(lastKeyPressTime) < 0.3 {
                        // Double tap - Next
                        pendingAction?.cancel()
                        DispatchQueue.main.async { vm.nextTrack() }
                        lastKeyCode = 0 
                    } else {
                        // Potential single tap - Enter
                        lastKeyPressTime = now
                        lastKeyCode = 124
                        let action = DispatchWorkItem { [weak vm] in
                            vm?.activateSelection()
                        }
                        pendingAction = action
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
                    }
                    return nil

                case 123: // Left arrow
                    let now = Date()
                    if lastKeyCode == 123 && now.timeIntervalSince(lastKeyPressTime) < 0.3 {
                        // Double tap - Previous
                        pendingAction?.cancel()
                        DispatchQueue.main.async { vm.previousTrack() }
                        lastKeyCode = 0
                    } else {
                        // Potential single tap - Back
                        lastKeyPressTime = now
                        lastKeyCode = 123
                        let action = DispatchWorkItem { [weak vm] in
                            vm?.closePlaylist()
                        }
                        pendingAction = action
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
                    }
                    return nil

                case 125: // Down arrow — navigate list if results visible, else volume down
                    let hasResults = MainActor.assumeIsolated {
                        vm.selectedPlaylist != nil || !vm.displayedResults.isEmpty
                    }
                    if hasResults {
                        return event // let SwiftUI keyboard shortcuts handle list navigation
                    } else {
                        DispatchQueue.main.async { vm.adjustVolume(-5) }
                        return nil
                    }

                case 126: // Up arrow — navigate list if results visible, else volume up
                    let hasResults = MainActor.assumeIsolated {
                        vm.selectedPlaylist != nil || !vm.displayedResults.isEmpty
                    }
                    if hasResults {
                        return event // let SwiftUI keyboard shortcuts handle list navigation
                    } else {
                        DispatchQueue.main.async { vm.adjustVolume(5) }
                        return nil
                    }

                default:
                    break
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
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        } completionHandler: {
            // Fire after animation so the panel is truly key before we ask SwiftUI
            // to focus the search field.
            NotificationCenter.default.post(name: .hudDidShow, object: nil)
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
    
    public func showOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.title = "MusicOverlay Setup"
            window.center()
            window.level = .floating
            window.isReleasedWhenClosed = false
            
            // Setup Liquid Glass for Onboarding
            let visualEffect = NSVisualEffectView()
            visualEffect.material = .hudWindow
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            visualEffect.appearance = NSAppearance(named: .vibrantDark)
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = 24.0
            visualEffect.layer?.masksToBounds = true
            visualEffect.layer?.borderWidth = 0.5
            visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            
            // Apply mask to fix "ghost corners"
            visualEffect.maskImage = .maskImage(cornerRadius: 24.0, size: window.contentRect(forFrameRect: window.frame).size)
            
            let rootView = OnboardingView(onClose: { [weak self] in
                self?.closeOnboardingWindow()
                self?.showHUD()
            })
            .fontDesign(.monospaced)
            
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            
            visualEffect.addSubview(hostingView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
            ])
            
            window.contentView = visualEffect
            
            self.onboardingWindow = window
        }
        
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}

extension Notification.Name {
    static let hudDidShow = Notification.Name("HUDDidShow")
}

extension NSImage {
    static func maskImage(cornerRadius: CGFloat, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        return image
    }
}
