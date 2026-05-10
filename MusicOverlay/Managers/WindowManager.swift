@preconcurrency import AppKit
import SwiftUI

public class HUDPanel: NSPanel {
    public override var canBecomeKey: Bool {
        return true
    }
}

@MainActor
public class WindowManager: NSObject {
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
    
    private override init() {
        super.init()
    }
    
    public func setupHUD() {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.center()
        
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
        panel.delegate = self
        self.hudPanel = panel
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WindowManager.shared.actuallyHideHUD()
            }
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            return WindowManager.shared.handleKeyDown(event)
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let panel = hudPanel, panel.isVisible == true else { return event }

        if event.keyCode == 53 {
            hideHUD()
            return nil
        }

        guard let vm = activeViewModel else { return event }
        let hasModifiers = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty

        if !hasModifiers {
            switch event.keyCode {
            case 49: // Space bar
                if let firstResponder = self.hudPanel?.firstResponder,
                   firstResponder is NSText || firstResponder is NSTextField {
                    return event
                }
                DispatchQueue.main.async { vm.togglePlayPause() }
                return nil

            case 124: // Right arrow
                let now = Date()
                if lastKeyCode == 124 && now.timeIntervalSince(lastKeyPressTime) < 0.3 {
                    pendingAction?.cancel()
                    DispatchQueue.main.async { vm.nextTrack() }
                    lastKeyCode = 0 
                } else {
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
                    pendingAction?.cancel()
                    DispatchQueue.main.async { vm.previousTrack() }
                    lastKeyCode = 0
                } else {
                    lastKeyPressTime = now
                    lastKeyCode = 123
                    let action = DispatchWorkItem { [weak vm] in
                        vm?.closePlaylist()
                    }
                    pendingAction = action
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
                }
                return nil

            case 125: // Down arrow
                let hasResults = vm.selectedPlaylist != nil || !vm.displayedResults.isEmpty
                if hasResults {
                    return event
                } else {
                    DispatchQueue.main.async { vm.adjustVolume(-5) }
                    return nil
                }

            case 126: // Up arrow
                let hasResults = vm.selectedPlaylist != nil || !vm.displayedResults.isEmpty
                if hasResults {
                    return event
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

    public func showHUD() {
        guard let panel = hudPanel, let vm = activeViewModel else { return }
        
        vm.isMinimized = false
        panel.alphaValue = 0.0
        
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let centerFrame = NSRect(
            x: visibleFrame.midX - fullSize.width / 2,
            y: visibleFrame.midY - fullSize.height / 2,
            width: fullSize.width,
            height: fullSize.height
        )
        panel.setFrame(centerFrame, display: true)
        panel.isMovableByWindowBackground = false
        
        if let visualEffect = panel.contentView as? NSVisualEffectView {
            visualEffect.layer?.cornerRadius = 24.0
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil as Any?)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1.0
        } completionHandler: {
            NotificationCenter.default.post(name: .hudDidShow, object: nil)
        }
    }
    
    public func hideHUD() {
        actuallyHideHUD()
    }

    public func toggleHUD() {
        guard let panel = hudPanel, let vm = activeViewModel else { return }
        if !panel.isVisible || panel.alphaValue < 0.1 {
            showHUD()
        } else if vm.isMinimized {
            expandHUD()
        } else {
            minimizeHUD()
        }
    }

    private let miniSize = NSSize(width: 240, height: 64)
    private let fullSize = NSSize(width: 620, height: 420)

    public func minimizeHUD() {
        guard let panel = hudPanel, let vm = activeViewModel, !vm.isMinimized else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                vm.isMinimized = true
                
                let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
                let visibleFrame = screen.visibleFrame
                
                let targetFrame: NSRect
                if let savedOriginString = UserDefaults.standard.string(forKey: "MiniPlayerOrigin"),
                   let savedOrigin = NSPointFromString(savedOriginString) as NSPoint? {
                    targetFrame = NSRect(origin: savedOrigin, size: self.miniSize)
                } else {
                    targetFrame = NSRect(
                        x: visibleFrame.maxX - self.miniSize.width - 24,
                        y: visibleFrame.minY + 24,
                        width: self.miniSize.width,
                        height: self.miniSize.height
                    )
                }
                
                panel.setFrame(targetFrame, display: true)
                panel.isMovableByWindowBackground = true
                
                if let visualEffect = panel.contentView as? NSVisualEffectView {
                    visualEffect.layer?.cornerRadius = 16.0
                    visualEffect.maskImage = .maskImage(cornerRadius: 16.0, size: self.miniSize)
                }
                
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 1.0
                }
            }
        })
    }

    public func expandHUD() {
        guard let panel = hudPanel, let vm = activeViewModel, vm.isMinimized else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                vm.isMinimized = false
                
                let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
                let visibleFrame = screen.visibleFrame
                let targetFrame = NSRect(
                    x: visibleFrame.midX - self.fullSize.width / 2,
                    y: visibleFrame.midY - self.fullSize.height / 2,
                    width: self.fullSize.width,
                    height: self.fullSize.height
                )
                
                panel.setFrame(targetFrame, display: true)
                panel.isMovableByWindowBackground = false
                
                if let visualEffect = panel.contentView as? NSVisualEffectView {
                    visualEffect.layer?.cornerRadius = 24.0
                    visualEffect.maskImage = .maskImage(cornerRadius: 24.0, size: self.fullSize)
                }
                
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 1.0
                } completionHandler: {
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil as Any?)
                }
            }
        })
    }

    public func actuallyHideHUD() {
        guard let panel = hudPanel, panel.isVisible else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil as Any?)
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
            
            let rootView = OnboardingView(onClose: { [weak self] in
                Task { @MainActor in
                    self?.closeOnboardingWindow()
                    self?.showHUD()
                }
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
        
        onboardingWindow?.makeKeyAndOrderFront(nil as Any?)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}

extension WindowManager: NSWindowDelegate {
    public func windowDidMove(_ notification: Notification) {
        guard let panel = hudPanel, let vm = activeViewModel, vm.isMinimized else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "MiniPlayerOrigin")
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
