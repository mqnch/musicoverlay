@preconcurrency import AppKit
import QuartzCore

/// Drives a smooth, fixed-distance-per-tick programmatic scroll on a single
/// `NSScrollView`. One engine is created per scroll view (cached by the caller).
///
/// macOS applies non-linear acceleration to discrete mouse-wheel events, which
/// makes mouse scrolling feel jittery and inconsistent (fast flicks jump far,
/// slow ticks barely move). By consuming the raw wheel event and instead
/// advancing a fixed step toward an eased target, every notch travels the same
/// distance regardless of how fast the wheel is turned.
@MainActor
final class SmoothScrollEngine {
    private weak var scrollView: NSScrollView?
    private var displayLink: CADisplayLink?
    private var targetY: CGFloat = 0
    private var isAnimating = false

    /// Points scrolled per wheel notch. A single constant value is what kills
    /// the speed-dependent variance of the native acceleration curve.
    private let stepPerLine: CGFloat = 50

    /// Fraction of the remaining distance covered each frame. Higher = snappier,
    /// lower = floatier. ~0.25 settles in roughly 6-8 frames.
    private let easeFactor: CGFloat = 0.25

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        self.targetY = scrollView.contentView.bounds.origin.y
    }

    /// Advances the scroll target by one fixed step in the given direction.
    /// `direction` should be the sign of the desired clip-origin movement
    /// (positive = scroll toward the bottom of the content).
    func addStep(direction: CGFloat) {
        guard let scrollView, direction != 0 else { return }
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let viewportHeight = clipView.bounds.height
        let maxY = max(0, documentHeight - viewportHeight)

        // If we're idle, re-sync the target to the live position so an
        // interrupted/drag-driven scroll doesn't cause a jump.
        if !isAnimating {
            targetY = clipView.bounds.origin.y
        }

        let step = (direction > 0 ? 1 : -1) * stepPerLine
        targetY = min(maxY, max(0, targetY + step))
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !isAnimating, let scrollView else { return }
        isAnimating = true
        let link = scrollView.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { stop(); return }
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        let diff = targetY - origin.y

        if abs(diff) < 0.5 {
            origin.y = targetY
            clipView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clipView)
            stop()
            return
        }

        origin.y += diff * easeFactor
        clipView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isAnimating = false
    }

    /// Cancels any in-flight animation and resets state. Must be called when the
    /// host window is hidden: ordering the window out kills the display link
    /// without `step` ever running `stop()`, which would otherwise leave
    /// `isAnimating == true` and silently block every future mouse-wheel scroll.
    func cancel() {
        stop()
    }
}

/// Returns the `NSScrollView` directly under the cursor for a given wheel event,
/// or `nil` if the cursor isn't over a scrollable area.
@MainActor
func scrollViewUnderCursor(in contentView: NSView, atWindowPoint windowPoint: CGPoint) -> NSScrollView? {
    guard let hit = contentView.hitTest(windowPoint) else { return nil }
    return hit.enclosingScrollView
}
