import SwiftUI
import Combine

private let accentGreen = Color(red: 0.18, green: 0.8, blue: 0.44)

// MARK: - UI scale

/// Largest value the UI Scale slider allows (`HUDViewModel.setUIScale` clamps to
/// this). Artwork is always requested at this scale so the pixel size — and
/// therefore the cache key — never depends on the *current* scale. Without that,
/// dragging the slider would invalidate every cached thumbnail and refetch the
/// whole visible list from Spotify on every tick.
let maxUIScale: CGFloat = 1.5

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier applied to every font size, frame and padding in the HUD.
    ///
    /// This is a *layout* scale, not `.scaleEffect`. `scaleEffect` magnifies the
    /// finished raster, so text rendered for a 2x display gets stretched to 3x at
    /// 1.5 and goes soft. Scaling the design values instead means text is laid
    /// out and rendered at its true size, so it stays sharp at any scale.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

/// Gives a view `s(_:)` for scaling design constants. Conformers declare
/// `@Environment(\.uiScale) var uiScale`.
protocol UIScaled {
    var uiScale: CGFloat { get }
}

extension UIScaled {
    /// Scales a design constant (font size, padding, frame dimension).
    func s(_ value: CGFloat) -> CGFloat { value * uiScale }
}

// MARK: - Image cache

/// Shared in-memory cache of decoded artwork thumbnails.
/// Avoids re-downloading and (more importantly) re-decoding images as
/// List rows recycle during scrolling.
private enum ImageCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1500
        // Entries are downsampled thumbnails (tens of KB), but bound the cache in
        // bytes too: caching full-size 640x640 artwork meant ~6.4MB per entry, so
        // a long scroll through a big playlist could retain multiple GB and stall
        // the app under memory pressure.
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Keyed by URL *and* render size. The same artwork is displayed at 22, 32,
    /// 40 and 170pt; each needs its own thumbnail, and a URL-only key would let
    /// whichever size loaded first win (a row's 32pt thumbnail could end up
    /// upscaled in the 170pt now-playing panel).
    static func key(_ url: URL, size: CGFloat) -> NSString {
        "\(url.absoluteString)@\(Int(size))" as NSString
    }

    static func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height) * 4
    }
}

/// Decodes `data` directly into a bitmap no larger than `maxPixel` on a side.
///
/// `kCGImageSourceShouldCacheImmediately` forces the decode to happen here, on
/// the calling thread, instead of lazily at draw time. Handing SwiftUI a
/// full-size `NSImage` instead costs ~4ms of main-thread decode per row as it
/// scrolls into view — which is what made scrolling freeze in bursts.
nonisolated private func downsampledImage(from data: Data, maxPixel: CGFloat) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
    ) else { return nil }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

/// Cache for decoded bundle (app asset) images so repeated view bodies don't
/// re-read and re-decode local files from disk on every render.
enum BundleImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(resource: String, ext: String) -> NSImage? {
        let key = "\(resource).\(ext)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Async Image helper

private struct RemoteImage: View, UIScaled {
    /// Unscaled design size. The view applies `uiScale` itself, so call sites
    /// pass a plain constant and the cache key stays scale-independent.
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.uiScale) var uiScale
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .overlay(Image(systemName: "music.note")
                        .foregroundColor(.white.opacity(0.3))
                        .font(.system(size: s(size) * 0.35)))
            }
        }
        .frame(width: s(size), height: s(size))
        .clipShape(RoundedRectangle(cornerRadius: s(cornerRadius), style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }

        // Keyed on the *unscaled* size, so changing the UI scale never
        // invalidates the cache or triggers a refetch.
        let key = ImageCache.key(url, size: size)

        // Cache hit: set immediately, no network / no re-decode.
        if let cached = ImageCache.shared.object(forKey: key) {
            if image !== cached { image = cached }
            return
        }

        // Always decode for the largest scale the slider allows, so the same
        // thumbnail stays sharp at every scale without ever being refetched.
        // Read the scale factor here, on the main actor, before hopping off.
        let maxPixel = size * maxUIScale * (NSScreen.main?.backingScaleFactor ?? 2)

        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        // Decode and downsample off the main thread so the main thread only ever
        // composites an already-decoded thumbnail.
        let thumbnail = await Task.detached(priority: .utility) {
            downsampledImage(from: data, maxPixel: maxPixel)
        }.value
        guard let thumbnail else { return }

        ImageCache.shared.setObject(thumbnail, forKey: key, cost: ImageCache.cost(of: thumbnail))

        // Guard against row recycling to a different URL while we were loading.
        guard self.url == url else { return }
        image = thumbnail
    }
}

// MARK: - Liked Songs artwork

private struct LikedSongsArtwork: View, UIScaled {
    let size: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.uiScale) var uiScale

    var body: some View {
        RoundedRectangle(cornerRadius: s(cornerRadius), style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.27, green: 0.20, blue: 0.85),
                             Color(red: 0.45, green: 0.55, blue: 0.98)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "heart.fill")
                    .font(.system(size: s(size) * 0.5, weight: .bold))
                    .foregroundColor(.white)
            )
            .frame(width: s(size), height: s(size))
    }
}

// MARK: - Time formatter

private func formatTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Playback Controls

private struct PlaybackControlsView: View, UIScaled {
    @ObservedObject var viewModel: HUDViewModel
    @Environment(\.uiScale) var uiScale
    /// Observed separately from `viewModel` so the 0.5s position updates only
    /// re-render this view — see `HUDViewModel.PlaybackProgress`.
    @ObservedObject var progress: HUDViewModel.PlaybackProgress

    var body: some View {
        VStack(spacing: s(8)) {
            // ── Progress slider ──────────────────────────────────────────
            VStack(spacing: s(2)) {
                Slider(
                    value: $progress.position,
                    in: 0...max(1, progress.duration),
                    onEditingChanged: { editing in
                        progress.isSeeking = editing
                        if !editing { viewModel.commitSeek() }
                    }
                )
                .accentColor(.white)
                .tint(.white)
                .foregroundColor(.white)
                .controlSize(.mini)

                HStack {
                    Text(formatTime(progress.position))
                        .font(.system(size: s(9), design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer()
                    Text(formatTime(progress.duration))
                        .font(.system(size: s(9), design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }

            // ── Row 1: Prev / Play-Pause / Next ─────────────────────────
            HStack(spacing: s(28)) {
                Button(action: { viewModel.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: s(18), weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(s(8))
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Previous")

                Button(action: { viewModel.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: s(44), height: s(44))
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: s(18), weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: viewModel.isPlaying ? 0 : 0, y: viewModel.isPlaying ? 0 : -1.0)
                    }
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Button(action: { viewModel.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: s(18), weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(s(8))
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Next")
            }
            .frame(maxWidth: .infinity)

            // ── Row 2: Shuffle / Repeat ──────────────────────────────────
            HStack(spacing: s(40)) {
                Button(action: { viewModel.toggleShuffle() }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: s(14), weight: .medium))
                        .foregroundColor(viewModel.isShuffled
                                         ? accentGreen
                                         : .white.opacity(0.45))
                        .padding(s(6))
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Shuffle")

                Button(action: { viewModel.cycleRepeat() }) {
                    Image(systemName: viewModel.repeatMode.systemImage)
                        .font(.system(size: s(14), weight: .medium))
                        .foregroundColor(viewModel.repeatMode.isActive
                                         ? accentGreen
                                         : .white.opacity(0.45))
                        .padding(s(6))
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Repeat")
            }
            .frame(maxWidth: .infinity)

        }
    }
}

// MARK: - Now Playing Panel (left)

private struct NowPlayingPanel: View, UIScaled {
    let track: TrackInfo?
    @Environment(\.uiScale) var uiScale
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        VStack(alignment: .center, spacing: s(8)) {
            if let track = track {
                RemoteImage(url: track.albumArtURL, size: 170, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.5), radius: s(12), x: 0, y: 5)
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: s(2)) {
                    Text(track.title)
                        .font(.system(size: s(13), weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(track.artist)
                        .font(.system(size: s(11)))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                RemoteImage(url: nil, size: 170, cornerRadius: 12)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Nothing playing")
                    .font(.system(size: s(12)))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Controls directly below art — no Spacer pushing them down
            PlaybackControlsView(viewModel: viewModel, progress: viewModel.progress)
                .padding(.top, s(4))
        }
        .frame(width: s(190))
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View, UIScaled {
    @EnvironmentObject var stateController: StateController
    @Environment(\.uiScale) var uiScale
    let result: SearchResult
    let isSelected: Bool

    private var isPlaying: Bool {
        if case .track(let track) = result {
            return track.uri == stateController.currentTrack?.id
        }
        return false
    }

    var body: some View {
        HStack(spacing: s(10)) {
            switch result {
            case .track(let track):
                Image(systemName: "music.note")
                    .font(.system(size: s(11)))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: s(32), height: s(32))
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: s(5), style: .continuous))

                VStack(alignment: .leading, spacing: s(2)) {
                    Text(track.title)
                        .font(.system(size: s(13), weight: .medium))
                        .foregroundColor(isPlaying ? accentGreen : .white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: s(11)))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                Text(track.durationString)
                    .font(.system(size: s(11), design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))

            case .playlist(let playlist):
                if playlist.isLikedSongs {
                    LikedSongsArtwork(size: 32, cornerRadius: 5)
                } else {
                    RemoteImage(url: playlist.imageURL, size: 32, cornerRadius: 5)
                }

                VStack(alignment: .leading, spacing: s(2)) {
                    Text(playlist.name)
                        .font(.system(size: s(13), weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let count = playlist.trackCount {
                        Text("\(count) tracks")
                            .font(.system(size: s(11)))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: s(10), weight: .semibold))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .padding(.vertical, s(8))
        .padding(.horizontal, s(10))
        .background(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
        )
        .hoverHighlight(.background)
    }
}

// MARK: - Playlist Track Row

private struct PlaylistTrackRow: View, UIScaled {
    @EnvironmentObject var stateController: StateController
    @Environment(\.uiScale) var uiScale
    let track: SpotifyTrack
    let index: Int
    let isSelected: Bool

    private var isPlaying: Bool {
        track.uri == stateController.currentTrack?.id
    }

    var body: some View {
        HStack(spacing: s(10)) {
            Text("\(index + 1)")
                .font(.system(size: s(11), design: .monospaced))
                .foregroundColor(isPlaying ? accentGreen : .white.opacity(0.25))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: s(18), alignment: .trailing)

            RemoteImage(url: track.albumArtURL, size: 32, cornerRadius: 4)

            VStack(alignment: .leading, spacing: s(2)) {
                Text(track.title)
                    .font(.system(size: s(13), weight: .medium))
                    .foregroundColor(isPlaying ? accentGreen : .white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: s(11)))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Text(track.durationString)
                .font(.system(size: s(11), design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.vertical, s(8))
        .padding(.horizontal, s(10))
        .background(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .hoverHighlight(.background)
    }
}

// MARK: - Right Panel

private struct RightPanel: View, UIScaled {
    @ObservedObject var viewModel: HUDViewModel
    @Environment(\.uiScale) var uiScale
    @State private var searchScroll = ScrollController()
    @State private var playlistScroll = ScrollController()

    var body: some View {
        if viewModel.selectedPlaylist != nil {
            playlistDetailView
        } else {
            searchResultsView
        }
    }
}

// MARK: - Custom Scroll Bar helpers

private struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var scrollOffset: CGFloat = 0
}

/// Holds live scroll metrics plus a handle on the backing `NSScrollView`. Kept as
/// a reference type (held via `@State`, not `@StateObject`) so that per-frame
/// metric updates only re-render the `CustomScrollbar` that observes it — NOT the
/// parent view that builds the List. This prevents the list from being rebuilt on
/// every scroll frame, which is what made scrolling stutter/jump.
private final class ScrollController: ObservableObject {
    @Published var metrics = ScrollMetrics()

    /// Captured by `ScrollViewConfigurator`. Deliberately *not* `@Published`:
    /// wiring it up must never trigger a SwiftUI update.
    weak var scrollView: NSScrollView?

    /// Scrolls the clip view to an absolute content offset.
    ///
    /// This drives AppKit directly instead of going through SwiftUI's
    /// `.scrollPosition(_:)`. A `ScrollPosition` binding lives in the enclosing
    /// view's `@State`, so SwiftUI both writes to it as the user scrolls *and*
    /// re-applies the stored offset whenever the content changes — which is what
    /// made scrolling snap, most visibly on a trackpad.
    func scroll(toOffsetY y: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, documentHeight - clipView.bounds.height)
        var origin = clipView.bounds.origin
        origin.y = min(maxY, max(0, y))
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}

/// Captures the enclosing `NSScrollView` (so the custom scrollbar can scroll it
/// directly) and hides the native legacy scroller. Placed as a zero-size view
/// inside the scrolled content so its backing view lives in the scroll view's
/// document hierarchy and `enclosingScrollView` resolves.
///
/// The configuration runs once per backing scroll view, never on every update:
/// assigning `hasVerticalScroller` / `scrollerStyle` re-tiles the scroll view,
/// and doing that mid-gesture visibly interrupts trackpad scrolling.
private struct ScrollViewConfigurator: NSViewRepresentable {
    let controller: ScrollController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The backing NSScrollView isn't in the hierarchy yet during makeNSView,
        // so resolve it one runloop turn later.
        DispatchQueue.main.async { configure(view, retriesLeft: 5) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only re-resolve if we lost the handle (e.g. the List rebuilt its
        // backing scroll view). Otherwise this is a no-op.
        guard controller.scrollView == nil else { return }
        DispatchQueue.main.async { configure(nsView, retriesLeft: 5) }
    }

    /// Resolves the enclosing scroll view, retrying a few frames if SwiftUI
    /// hasn't attached this view to the document hierarchy yet. Without the
    /// retry a missed first attempt would leave the scrollbar undraggable until
    /// the next List update — wheel and trackpad scrolling would still work, so
    /// the failure would be easy to miss.
    private func configure(_ view: NSView, retriesLeft: Int) {
        guard let scrollView = view.enclosingScrollView else {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.async { configure(view, retriesLeft: retriesLeft - 1) }
            return
        }
        controller.scrollView = scrollView
        guard scrollView.hasVerticalScroller || scrollView.hasHorizontalScroller else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
    }
}

/// Thin overlay scrollbar. Reads metrics published by `onScrollGeometryChange`
/// and scrolls via `ScrollController.scroll(toOffsetY:)`, so nothing it does
/// feeds back into the scroll view's own view state.
private struct CustomScrollbar: View, UIScaled {
    @ObservedObject var controller: ScrollController
    @Environment(\.uiScale) var uiScale

    /// Distance from the top of the thumb to where the drag started, so dragging
    /// tracks the grab point instead of snapping the thumb's centre to the cursor.
    @State private var grabOffset: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let metrics = controller.metrics
            let trackHeight = geo.size.height
            let scrollRange = metrics.contentHeight - metrics.viewportHeight
            let scrollable = scrollRange > 0.5 && metrics.contentHeight > 0
            let thumbHeight = max(s(20), trackHeight * (metrics.viewportHeight / max(1, metrics.contentHeight)))
            let thumbRange = max(1, trackHeight - thumbHeight)
            let thumbOffset = (metrics.scrollOffset / max(1, scrollRange)) * thumbRange

            ZStack(alignment: .top) {
                // ── Gutter ───────────────────────────────────────────────────
                RoundedRectangle(cornerRadius: s(2))
                    .fill(Color.white.opacity(0.05))
                    .frame(width: s(4))

                // ── Thumb ────────────────────────────────────────────────────
                RoundedRectangle(cornerRadius: s(2))
                    .fill(Color.white.opacity(0.3))
                    .frame(width: s(4), height: thumbHeight)
                    .offset(y: thumbOffset)
            }
            .frame(width: s(16))
            .contentShape(Rectangle())
            .opacity(scrollable ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: scrollable)
            .allowsHitTesting(scrollable)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let grab: CGFloat
                        if let existing = grabOffset {
                            grab = existing
                        } else {
                            let start = value.startLocation.y
                            let onThumb = start >= thumbOffset && start <= thumbOffset + thumbHeight
                            // Pressing the gutter jumps the thumb's centre to the
                            // cursor; pressing the thumb keeps it under the finger.
                            grab = onThumb ? start - thumbOffset : thumbHeight / 2
                            grabOffset = grab
                        }
                        let progress = min(1, max(0, (value.location.y - grab) / thumbRange))
                        controller.scroll(toOffsetY: progress * scrollRange)
                    }
                    .onEnded { _ in grabOffset = nil }
            )
        }
        .frame(width: s(16))
    }
}

// MARK: - Window Dragging

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return DraggableView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    class DraggableView: NSView {
        override func mouseDown(with event: NSEvent) {
            // Native macOS window dragging
            window?.performDrag(with: event)
        }
    }
}

extension RightPanel {


    @ViewBuilder
    private var searchResultsView: some View {
        if viewModel.isSearching {
            HStack {
                ProgressView().scaleEffect(0.7).padding(.vertical, s(8))
                Spacer()
            }
            .padding(.horizontal, s(10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if viewModel.displayedResults.isEmpty {
            Text(viewModel.searchText.isEmpty ? "Your playlists will appear here" : "No results")
                .font(.system(size: s(13)))
                .foregroundColor(.white.opacity(0.3))
                .padding(.top, s(20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack(alignment: .trailing) {
                ScrollViewReader { proxy in
                    List {
                        ScrollViewConfigurator(controller: searchScroll)
                            .frame(height: s(0))
                            .plainListRow(uiScale)
                        ForEach(0..<viewModel.displayedResults.count, id: \.self) { index in
                            let result = viewModel.displayedResults[index]
                            SearchResultRow(result: result, isSelected: index == viewModel.selectionIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.playResult(result) }
                                .plainListRow(uiScale)
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 0)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                        ScrollMetrics(
                            contentHeight: geo.contentSize.height,
                            viewportHeight: geo.containerSize.height,
                            scrollOffset: geo.contentOffset.y
                        )
                    } action: { _, newValue in
                        searchScroll.metrics = newValue
                    }
                    .onChange(of: viewModel.selectionIndex) { _, idx in
                        guard let idx else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }

                CustomScrollbar(controller: searchScroll)
                    .padding(.vertical, s(4))
                    .padding(.trailing, s(2))
            }
        }
    }

    @ViewBuilder
    private var playlistDetailView: some View {
        VStack(spacing: s(0)) {
            HStack(spacing: s(8)) {
                Button(action: { viewModel.closePlaylist() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: s(16), weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(s(8))
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let playlist = viewModel.selectedPlaylist {
                    if playlist.isLikedSongs {
                        LikedSongsArtwork(size: 22, cornerRadius: 3)
                    } else {
                        RemoteImage(url: playlist.imageURL, size: 22, cornerRadius: 3)
                    }
                    Text(playlist.name)
                        .font(.system(size: s(14), weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, s(10))
            .padding(.bottom, s(8))

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.bottom, s(4))

            if viewModel.isLoadingTracks {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Spacer()
            } else if viewModel.displayedPlaylistTracks.isEmpty {
                Spacer()
                Text("No tracks found")
                    .font(.system(size: s(13)))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
            } else {
                ZStack(alignment: .trailing) {
                    ScrollViewReader { proxy in
                        List {
                            ScrollViewConfigurator(controller: playlistScroll)
                                .frame(height: s(0))
                                .plainListRow(uiScale)
                            ForEach(Array(viewModel.displayedPlaylistTracks.enumerated()), id: \.element.id) { index, track in
                                PlaylistTrackRow(track: track, index: index, isSelected: index == viewModel.selectionIndex)
                                    .onTapGesture {
                                        viewModel.playTrack(track)
                                    }
                                    .contentShape(Rectangle())
                                    .plainListRow(uiScale)
                            }

                            if viewModel.tracksHasMore {
                                HStack {
                                    Spacer()
                                    ProgressView().scaleEffect(0.6)
                                    Spacer()
                                }
                                .frame(height: s(36))
                                .onAppear { viewModel.loadMoreTracks() }
                                .plainListRow(uiScale)
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 0)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                            ScrollMetrics(
                                contentHeight: geo.contentSize.height,
                                viewportHeight: geo.containerSize.height,
                                scrollOffset: geo.contentOffset.y
                            )
                        } action: { _, newValue in
                            playlistScroll.metrics = newValue
                            // Prefetch the next page as the user nears the bottom.
                            // This runs on every scroll frame, so check the cheap
                            // local flags before calling into the view model.
                            guard viewModel.tracksHasMore, !viewModel.isLoadingMoreTracks else { return }
                            let distanceToBottom = newValue.contentHeight - (newValue.scrollOffset + newValue.viewportHeight)
                            if distanceToBottom < 600 {
                                viewModel.loadMoreTracks()
                            }
                        }
                        .onChange(of: viewModel.selectionIndex) { _, idx in
                            guard let idx, idx >= 0, idx < viewModel.displayedPlaylistTracks.count else { return }
                            let trackID = viewModel.displayedPlaylistTracks[idx].id
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(trackID, anchor: .center)
                            }
                        }
                    }

                    CustomScrollbar(controller: playlistScroll)
                        .padding(.vertical, s(4))
                        .padding(.trailing, s(2))
                }
            }
        }
    }
}

// MARK: - Settings View

private struct SettingsView: View, UIScaled {
    @ObservedObject var viewModel: HUDViewModel
    @Environment(\.uiScale) var uiScale
    @EnvironmentObject var stateController: StateController
    @State private var scrollController = ScrollController()

    var body: some View {
        VStack(spacing: s(0)) {
            ZStack(alignment: .trailing) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: s(16)) {
                        HStack(spacing: s(12)) {
                            if let nsImage = BundleImageCache.image(resource: "logo", ext: "png") {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: s(32), height: s(32))
                            }

                            Text("Settings")
                                .font(.system(size: s(20), weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.bottom, s(4))

                        // Mini Player Toggle
                        SettingRow(
                            title: "Enable Mini Player",
                            description: "Automatically minimize to a small window when inactive or after playing a track.",
                            isOn: Binding(
                                get: { viewModel.isMiniPlayerEnabled },
                                set: { _ in viewModel.toggleMiniPlayer() }
                            )
                        )

                        Divider().background(Color.white.opacity(0.1))

                        // Menu Bar Icon Toggle
                        SettingRow(
                            title: "Show in Menu Bar",
                            description: "Add a music icon to the macOS menu bar to quickly open or quit the app.",
                            isOn: Binding(
                                get: { viewModel.showMenuBarIcon },
                                set: { _ in viewModel.toggleMenuBarIcon() }
                            )
                        )

                        Divider().background(Color.white.opacity(0.1))

                        // Window Transparency Slider
                        SettingSliderRow(
                            title: "Window Transparency",
                            description: "Blend between frosted Apple glass and a solid opaque background.",
                            value: Binding(
                                get: { viewModel.windowOpacity },
                                set: { viewModel.setWindowOpacity($0) }
                            ),
                            range: 0.0...1.0
                        )

                        Divider().background(Color.white.opacity(0.1))

                        // UI Scale Slider
                        SettingSliderRow(
                            title: "UI Scale",
                            description: "Adjust the size of the HUD, mini player, and text.",
                            value: Binding(
                                get: { Double(viewModel.uiScale) },
                                set: { viewModel.setUIScale(CGFloat($0)) }
                            ),
                            range: 0.8...1.5,
                            displayValue: { "\(Int($0 * 100))%" }
                        )

                        Divider().background(Color.white.opacity(0.1))

                        // Hotkey Customization
                        HStack(spacing: s(12)) {
                            VStack(alignment: .leading, spacing: s(4)) {
                                Text("Hotkey Gesture")
                                    .font(.system(size: s(14), weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Double-tap to toggle HUD")
                                    .font(.system(size: s(12)))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            Menu {
                                ForEach(["Shift", "Control", "Option", "Command"], id: \.self) { mod in
                                    Button(mod) { viewModel.updateHotkeyModifier(mod) }
                                }
                            } label: {
                                HStack(spacing: s(4)) {
                                    Text(viewModel.hotkeyModifier)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: s(10)))
                                }
                                .font(.system(size: s(13), weight: .medium))
                                .padding(.horizontal, s(10))
                                .padding(.vertical, s(6))
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(s(8))
                            }
                            .menuStyle(.button)
                        }
                        .padding(.vertical, s(4))

                        Divider().background(Color.white.opacity(0.1))

                        // Service Info & Actions
                        HStack(spacing: s(12)) {
                            VStack(alignment: .leading, spacing: s(4)) {
                                Text("Active Service")
                                    .font(.system(size: s(14), weight: .semibold))
                                    .foregroundColor(.white)
                                Text(stateController.activeService?.name ?? "None")
                                    .font(.system(size: s(12)))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()

                            HStack(spacing: s(10)) {
                                Button(action: { viewModel.clearCache() }) {
                                    HStack(spacing: s(6)) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Clear Cache")
                                    }
                                    .font(.system(size: s(13), weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding(.horizontal, s(12))
                                    .padding(.vertical, s(8))
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(s(8))
                                    .hoverHighlight(.background)
                                }
                                .buttonStyle(.plain)

                                Button(action: { viewModel.logout() }) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: s(14), weight: .bold))
                                        .foregroundColor(.red.opacity(0.7))
                                        .padding(s(10))
                                        .background(Color.red.opacity(0.15))
                                        .clipShape(Circle())
                                        .hoverHighlight()
                                }
                                .buttonStyle(.plain)
                                .help("Logout")
                            }
                        }
                        .padding(.vertical, s(4))
                    }
                    .padding(.trailing, s(20))
                    .padding(.bottom, s(8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Zero-size probe inside the scrolled content so the
                    // configurator can resolve the backing NSScrollView.
                    .overlay(alignment: .topLeading) {
                        ScrollViewConfigurator(controller: scrollController)
                            .frame(width: s(0), height: s(0))
                    }
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                    ScrollMetrics(
                        contentHeight: geo.contentSize.height,
                        viewportHeight: geo.containerSize.height,
                        scrollOffset: geo.contentOffset.y
                    )
                } action: { _, newValue in
                    scrollController.metrics = newValue
                }

                CustomScrollbar(controller: scrollController)
                    .padding(.vertical, s(4))
                    .padding(.trailing, s(2))
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("MusicOverlay v1.0.0")
                    .font(.system(size: s(10)))
                    .foregroundColor(.white.opacity(0.2))
                
                Spacer()
                
                Button(action: { viewModel.quitApp() }) {
                    HStack(spacing: s(6)) {
                        Image(systemName: "power")
                        Text("Quit App")
                    }
                    .font(.system(size: s(11), weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, s(10))
                    .padding(.vertical, s(6))
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(s(6))
                    .hoverHighlight(.background)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, s(12))
        }
        .padding(.horizontal, s(24))
        .padding(.bottom, s(24))
        .padding(.top, s(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingRow: View, UIScaled {
    let title: String
    @Environment(\.uiScale) var uiScale
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: s(16)) {
            VStack(alignment: .leading, spacing: s(4)) {
                Text(title)
                    .font(.system(size: s(14), weight: .semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(size: s(12)))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
        }
    }
}

private struct SettingSliderRow: View, UIScaled {
    let title: String
    @Environment(\.uiScale) var uiScale
    let description: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var displayValue: ((Double) -> String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: s(8)) {
            HStack(alignment: .top, spacing: s(16)) {
                VStack(alignment: .leading, spacing: s(4)) {
                    Text(title)
                        .font(.system(size: s(14), weight: .semibold))
                        .foregroundColor(.white)
                    Text(description)
                        .font(.system(size: s(12)))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(displayValue?(value) ?? "\(Int((value / range.upperBound) * 100))%")
                    .font(.system(size: s(12), weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()
            }

            Slider(value: $value, in: range)
                .accentColor(.white)
                .tint(.white)
                .foregroundColor(.white)
                .controlSize(.mini)
        }
    }
}

// MARK: - HUDView

public struct HUDView: View, UIScaled {
    @EnvironmentObject var stateController: StateController

    /// The root is the *source* of the scale, so it reads the view model rather
    /// than the environment (`.environment(_:_:)` only reaches descendants).
    var uiScale: CGFloat { viewModel.uiScale }
    @StateObject private var viewModel: HUDViewModel
    @FocusState private var isSearchFocused: Bool

    // 0.5s for near-instant track updates
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    public init(stateController: StateController) {
        _viewModel = StateObject(wrappedValue: HUDViewModel(stateController: stateController))
    }

    private var miniPlayerView: some View {
        HStack(spacing: s(12)) {
            if let track = stateController.currentTrack {
                RemoteImage(url: track.albumArtURL, size: 40, cornerRadius: 8)
                
                VStack(alignment: .leading, spacing: s(2)) {
                    Text(track.title)
                        .font(.system(size: s(13), weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: s(12)))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                Text("Nothing playing")
                    .font(.system(size: s(13), weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.horizontal, s(12))
        .frame(width: s(HUDLayout.miniSize.width), height: s(HUDLayout.miniSize.height))
        .background(WindowDragArea())
        .contentShape(Rectangle())
        .onTapGesture {
            WindowManager.shared.expandHUD()
        }
    }

    private var fullHUDView: some View {
        VStack(spacing: s(0)) {
            HStack(spacing: s(12)) {
                // ── Search bar ──────────────────────────────────────────────
                HStack(spacing: s(10)) {
                    if viewModel.isSearching {
                        ProgressView().scaleEffect(0.65).frame(width: s(16))
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: s(15), weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    TextField("Search playlists/songs…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .font(.system(size: s(17), weight: .medium))
                        .foregroundColor(.white)

                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.3))
                                .font(.system(size: s(14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, s(16))
                .padding(.vertical, s(12))
                .background(
                    RoundedRectangle(cornerRadius: s(14), style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: s(14), style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: s(0.5))
                        )
                )

                // ── Settings Button ─────────────────────────────────────────
                Button(action: { viewModel.toggleSettings() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: s(18)))
                        .foregroundColor(viewModel.showSettings ? .white : .white.opacity(0.6))
                        .offset(y: s(-1)) // Move up one
                        .frame(width: s(44), height: s(44))
                        .contentShape(Rectangle())
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, s(16))
            .padding(.top, s(14))
            .padding(.bottom, s(10))

            // ── Main Content ────────────────────────────────────────────
            if viewModel.showSettings {
                SettingsView(viewModel: viewModel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HStack(alignment: .top, spacing: s(0)) {
                    NowPlayingPanel(track: stateController.currentTrack, viewModel: viewModel)
                        .padding(.leading, s(16))
                        .padding(.trailing, s(12))

                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: s(0.5))
                        .padding(.vertical, s(12))

                    RightPanel(viewModel: viewModel)
                        .padding(.leading, s(12))
                        .padding(.trailing, s(8))
                }
                .padding(.bottom, s(14))
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: s(HUDLayout.fullSize.width), height: s(HUDLayout.fullSize.height))
    }

    public var body: some View {
        ZStack {
            if viewModel.isMinimized {
                miniPlayerView
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                fullHUDView
                    .transition(.opacity.combined(with: .scale(scale: 1.05)))
            }
        }
        // Real layout scale: every design constant below is multiplied by
        // `uiScale` via `s(_:)`, so the tree lays out at its true size and text
        // renders sharp. Previously this was `.scaleEffect`, which magnified the
        // finished raster and made everything soft above 1.0.
        .environment(\.uiScale, viewModel.uiScale)
        .frame(
            width: s(viewModel.isMinimized ? HUDLayout.miniSize.width : HUDLayout.fullSize.width),
            height: s(viewModel.isMinimized ? HUDLayout.miniSize.height : HUDLayout.fullSize.height)
        )
        .background(Color.clear)
        .onAppear {
            WindowManager.shared.activeViewModel = viewModel
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudDidShow)) { _ in
        }
        .onReceive(timer) { _ in
            // Skip polling while the show fade-in is running so its state updates
            // and artwork loads don't stutter the animation.
            guard !WindowManager.shared.isAnimatingShow else { return }
            Task { await viewModel.refreshNowPlaying() }
        }
        .background(
            ZStack {
                if !viewModel.isMinimized {
                    WindowDragArea()
                    Color.black
                        .padding(s(12))
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        )
        .background(
            Group {
                Button("") { viewModel.moveSelectionUp()   }.keyboardShortcut(.upArrow,   modifiers: [])
                Button("") { viewModel.moveSelectionDown() }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") {
                    if viewModel.selectedPlaylist != nil { 
                        viewModel.closePlaylist() 
                    } else {
                        WindowManager.shared.minimizeHUD()
                    }
                }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
        )
    }
}

// MARK: - Hover Support

enum HoverStyle {
    case icon, background
}

private struct HoverHighlight: ViewModifier, UIScaled {
    let style: HoverStyle
    @Environment(\.uiScale) var uiScale
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(style == .background && isHovering ? Color.white.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
            .brightness(style == .icon && isHovering ? 0.25 : 0)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func hoverHighlight(_ style: HoverStyle = .icon) -> some View {
        self.modifier(HoverHighlight(style: style))
    }

    /// Strips List's default chrome (insets, background, separators) so custom
    /// rows render edge-to-edge with a small vertical gap and room for the
    /// overlaid custom scrollbar on the trailing edge.
    /// - Parameter scale: the ambient `uiScale`; this is a `View` extension so it
    ///   cannot read the environment itself.
    func plainListRow(_ scale: CGFloat = 1) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 1 * scale, leading: 0, bottom: 1 * scale, trailing: 20 * scale))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
