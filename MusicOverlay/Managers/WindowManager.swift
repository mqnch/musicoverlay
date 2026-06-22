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
    private weak var hudContainer: NSView?
    private weak var glassView: NSVisualEffectView?
    private var onboardingWindow: NSWindow?
    private var keyboardMonitor: Any?
    
    // Double-tap state
    private var lastKeyPressTime: Date = .distantPast
    private var lastKeyCode: UInt16 = 0
    private var lastShowTime: Date = .distantPast
    private var isAutoMinimizeLocked: Bool = false

    /// Set synchronously while a minimize (fade-out -> resize -> fade-in) is in
    /// flight. Clicking off the app fires two dismissal handlers at nearly the
    /// same instant; this flag lets the second one bail out so only one fade runs.
    private var isMinimizing: Bool = false

    /// True while the show fade-in is still running. Used to suppress the 0.5s
    /// now-playing poll so its `@Published` mutations / artwork tasks don't add
    /// work mid-animation and cause the fade to drop frames.
    public var isAnimatingShow: Bool {
        Date().timeIntervalSince(lastShowTime) < 0.25
    }
    private var pendingAction: DispatchWorkItem?

    /// Registered by HUDView so the keyboard monitor can route commands.
    public weak var activeViewModel: HUDViewModel?

    /// One smooth-scroll engine per `NSScrollView`, keyed by identity. Lets us
    /// normalize jittery mouse-wheel events into a consistent eased scroll.
    private var scrollEngines: [ObjectIdentifier: SmoothScrollEngine] = [:]

    /// Cancels and drops every cached scroll engine. Called on each show so a
    /// reused scroll view always gets a fresh engine: ordering the panel out can
    /// leave an engine stuck mid-animation (dead display link, `isAnimating`
    /// still true), which would block all mouse-wheel scrolling after reopening.
    private func resetScrollEngines() {
        for engine in scrollEngines.values { engine.cancel() }
        scrollEngines.removeAll()
    }
    
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
        
        // Container clips all layers to the rounded shape and carries the border.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 24.0
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // Solid background revealed as the glass layer fades toward opaque.
        let opaqueBackground = NSView()
        opaqueBackground.wantsLayer = true
        opaqueBackground.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0).cgColor

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .vibrantDark)
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 24.0
        visualEffect.layer?.masksToBounds = true
        visualEffect.maskImage = .maskImage(cornerRadius: 24.0)

        let hudView = HUDView(stateController: StateController.shared)
            .environmentObject(StateController.shared)
            .fontDesign(.monospaced)
        let hostingView = NSHostingView(rootView: hudView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Stack: opaque background (bottom) -> glass -> SwiftUI content (top).
        // Content sits above the glass so it stays sharp at any glass opacity.
        for layer in [opaqueBackground, visualEffect, hostingView] {
            container.addSubview(layer)
            layer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                layer.topAnchor.constraint(equalTo: container.topAnchor),
                layer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                layer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
        }

        let persistedOpacity = UserDefaults.standard.object(forKey: "HUDViewModel.WindowOpacity") as? Double
        visualEffect.alphaValue = CGFloat(persistedOpacity ?? 1.0)

        panel.contentView = container
        panel.delegate = self
        self.hudPanel = panel
        self.hudContainer = container
        self.glassView = visualEffect
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let vm = WindowManager.shared.activeViewModel else { return }
                if vm.isMinimized || WindowManager.shared.isAutoMinimizeLocked { return }
                
                if vm.isMiniPlayerEnabled {
                    WindowManager.shared.minimizeHUD()
                } else {
                    WindowManager.shared.actuallyHideHUD()
                }
            }
        }
        
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            return WindowManager.shared.handleKeyDown(event)
        }

        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { @MainActor event in
            return WindowManager.shared.handleScrollWheel(event)
        }

        // Global mouse-down monitor: fires only for clicks destined for OTHER apps
        // (never for clicks on our own panel or status bar icon), so it reliably
        // dismisses the HUD when the user clicks outside the app. This is robust
        // even when didResignActiveNotification doesn't fire (e.g. with a status item).
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                WindowManager.shared.handleClickOutside()
            }
        }

        prewarmHUD()
    }

    /// Crossfades the HUD between frosted Apple glass (value 1.0) and a solid
    /// opaque background (value 0.0) by fading only the glass layer. The SwiftUI
    /// content sits above the glass, so it stays fully sharp at any value. This is
    /// independent of `panel.alphaValue`, which is reserved for fade in/out
    /// animations and visibility checks, and covers both full and mini modes.
    public func setWindowOpacity(_ value: Double) {
        glassView?.alphaValue = CGFloat(value)
    }

    /// Builds and rasterizes the full SwiftUI HUD graph once, at launch, while the
    /// panel is parked off-screen and fully transparent. The first build of the
    /// HUD is by far the most expensive frame (it constructs the `List`'s backing
    /// `NSScrollView`/`NSTableView`, the corner hole-punch offscreen pass, and the
    /// behind-window blur). Paying that cost here keeps it from landing on the same
    /// runloop turn as a user-triggered show's fade, which is what intermittently
    /// dropped the first animation frames. Later shows only re-rasterize the
    /// already-built graph, which is cheap.
    private func prewarmHUD() {
        guard let panel = hudPanel else { return }
        let offscreen = NSRect(x: -10_000, y: -10_000, width: fullSize.width, height: fullSize.height)
        panel.setFrame(offscreen, display: false)
        panel.alphaValue = 0.0
        // orderFrontRegardless so warming never steals focus or app activation at launch.
        panel.orderFrontRegardless()

        // Force SwiftUI to evaluate bodies and lay out the whole tree now.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()

        // Let one runloop turn pass so SwiftUI's deferred List/NSTableView layout
        // and the first compositing pass complete, then put the panel away.
        DispatchQueue.main.async { [weak panel] in
            panel?.orderOut(nil as Any?)
        }
    }

    private func handleClickOutside() {
        guard let panel = hudPanel, panel.isVisible, panel.alphaValue > 0.1 else { return }
        guard let vm = activeViewModel else { return }
        if vm.isMinimized { return }
        // Ignore the brief window right after showing so a stray event tied to launch /
        // window activation can't auto-dismiss the HUD. A genuine user click moments
        // later (well within this window) is intentional and we honor it via `force`.
        if Date().timeIntervalSince(lastShowTime) < 0.6 { return }
        if vm.isMiniPlayerEnabled {
            minimizeHUD(force: true)
        } else {
            actuallyHideHUD()
        }
    }

    /// Normalizes mouse-wheel scrolling. Trackpad (precise) and momentum events
    /// pass straight through to native handling; discrete mouse-wheel notches are
    /// consumed and replayed as a smooth, fixed-step scroll to avoid macOS's
    /// speed-dependent acceleration that makes mouse scrolling feel jittery.
    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let panel = hudPanel, panel.isVisible, panel.alphaValue > 0.1 else { return event }
        guard event.window === panel, let contentView = panel.contentView else { return event }

        // Leave trackpads and inertial momentum scrolling untouched.
        if event.hasPreciseScrollingDeltas || event.momentumPhase != [] || event.phase != [] {
            return event
        }

        let deltaY = event.scrollingDeltaY
        guard deltaY != 0,
              let scrollView = scrollViewUnderCursor(in: contentView, atWindowPoint: event.locationInWindow)
        else { return event }

        let engine = scrollEngines[ObjectIdentifier(scrollView)] ?? {
            let new = SmoothScrollEngine(scrollView: scrollView)
            scrollEngines[ObjectIdentifier(scrollView)] = new
            return new
        }()

        // A positive scrollingDeltaY means "scroll up" (reveal earlier content),
        // which for a flipped document view decreases the clip origin.
        engine.addStep(direction: deltaY > 0 ? -1 : 1)
        return nil
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let panel = hudPanel, panel.isVisible == true else { return event }

        if event.keyCode == 53 {
            actuallyHideHUD()
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
        guard let panel = hudPanel else { return }
        
        resetScrollEngines()
        lastShowTime = Date()
        isAutoMinimizeLocked = true
        activeViewModel?.isMinimized = false
        
        // Unlock after 5 seconds to be absolutely sure we're past any launch/setup transitions
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.isAutoMinimizeLocked = false
        }
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
        
        hudContainer?.layer?.cornerRadius = 24.0
        glassView?.layer?.cornerRadius = 24.0
        glassView?.maskImage = .maskImage(cornerRadius: 24.0)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil as Any?)

        // Force the first-frame composite of the reused SwiftUI tree to happen now,
        // while the panel is still fully transparent. Because the panel is ordered
        // out on hide, the first render after re-showing is expensive; doing it here
        // keeps it from competing with the fade's animation ticks.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()

        // Start the fade on the next runloop turn so the animation begins on a clean
        // main thread, after the heavy first composite + activation are done. This
        // prevents the first one or two animation ticks from being dropped.
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1.0
            } completionHandler: {
                NotificationCenter.default.post(name: .hudDidShow, object: nil)
            }
        }
    }
    
    public func hideHUD() {
        if let vm = activeViewModel, !vm.isMiniPlayerEnabled {
            actuallyHideHUD()
        } else {
            minimizeHUD()
        }
    }

    public func toggleHUD() {
        guard let panel = hudPanel, let vm = activeViewModel else { return }
        if !panel.isVisible || panel.alphaValue < 0.1 {
            showHUD()
        } else if vm.isMinimized {
            expandHUD()
        } else {
            if vm.isMiniPlayerEnabled {
                minimizeHUD()
            } else {
                actuallyHideHUD()
            }
        }
    }

    private let miniSize = NSSize(width: 240, height: 64)
    private let fullSize = NSSize(width: 620, height: 420)

    public func minimizeHUD(force: Bool = false) {
        guard let panel = hudPanel, let vm = activeViewModel, !vm.isMinimized else { return }
        if isMinimizing { return }
        if !force && isAutoMinimizeLocked { return }
        isMinimizing = true
        
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
                
                self.hudContainer?.layer?.cornerRadius = 16.0
                self.glassView?.layer?.cornerRadius = 16.0
                self.glassView?.maskImage = .maskImage(cornerRadius: 16.0)
                
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 1.0
                } completionHandler: {
                    Task { @MainActor in
                        self.isMinimizing = false
                    }
                }
            }
        })
    }

    public func expandHUD() {
        guard let panel = hudPanel, let vm = activeViewModel, vm.isMinimized else { return }

        resetScrollEngines()
        lastShowTime = Date()
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
                
                self.hudContainer?.layer?.cornerRadius = 24.0
                self.glassView?.layer?.cornerRadius = 24.0
                self.glassView?.maskImage = .maskImage(cornerRadius: 24.0)
                
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
            visualEffect.layer?.cornerRadius = 16.0
            visualEffect.layer?.masksToBounds = true
            visualEffect.layer?.borderWidth = 0.5
            visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            
            let rootView = OnboardingView(onClose: { [weak self] in
                Task { @MainActor in
                    self?.showHUD()
                    self?.closeOnboardingWindow()
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
            
            // Move traffic lights inwards
            if let closeButton = window.standardWindowButton(.closeButton),
               let titleBarView = closeButton.superview {
                titleBarView.setFrameOrigin(NSPoint(x: 8, y: -8))
            }
            
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
    static func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
