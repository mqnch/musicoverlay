import SwiftUI
import Combine

private let accentGreen = Color(red: 0.18, green: 0.8, blue: 0.44)

// MARK: - Image cache

/// Shared in-memory cache of decoded artwork, keyed by URL.
/// Avoids re-downloading and (more importantly) re-decoding images as
/// LazyVStack rows recycle during scrolling.
private enum ImageCache {
    static let shared: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 1500
        return cache
    }()
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

private struct RemoteImage: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

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
                        .font(.system(size: size * 0.35)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }

        // Cache hit: set immediately, no network / no re-decode.
        if let cached = ImageCache.shared.object(forKey: url as NSURL) {
            if image !== cached { image = cached }
            return
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = NSImage(data: data) else { return }
        ImageCache.shared.setObject(loaded, forKey: url as NSURL)

        // Guard against row recycling to a different URL while we were loading.
        guard self.url == url else { return }
        image = loaded
    }
}

// MARK: - Liked Songs artwork

private struct LikedSongsArtwork: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - Time formatter

private func formatTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Playback Controls

private struct PlaybackControlsView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        VStack(spacing: 8) {
            // ── Progress slider ──────────────────────────────────────────
            VStack(spacing: 2) {
                Slider(
                    value: $viewModel.playbackPosition,
                    in: 0...max(1, viewModel.trackDuration),
                    onEditingChanged: { editing in
                        viewModel.isSeeking = editing
                        if !editing { viewModel.commitSeek() }
                    }
                )
                .accentColor(.white)
                .tint(.white)
                .foregroundColor(.white)
                .controlSize(.mini)

                HStack {
                    Text(formatTime(viewModel.playbackPosition))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer()
                    Text(formatTime(viewModel.trackDuration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
            }

            // ── Row 1: Prev / Play-Pause / Next ─────────────────────────
            HStack(spacing: 28) {
                Button(action: { viewModel.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(8)
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Previous")

                Button(action: { viewModel.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: viewModel.isPlaying ? 0 : 0, y: viewModel.isPlaying ? 0 : -1.0)
                    }
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Button(action: { viewModel.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(8)
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Next")
            }
            .frame(maxWidth: .infinity)

            // ── Row 2: Shuffle / Repeat ──────────────────────────────────
            HStack(spacing: 40) {
                Button(action: { viewModel.toggleShuffle() }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.isShuffled
                                         ? accentGreen
                                         : .white.opacity(0.45))
                        .padding(6)
                        .hoverHighlight()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Shuffle")

                Button(action: { viewModel.cycleRepeat() }) {
                    Image(systemName: viewModel.repeatMode.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.repeatMode.isActive
                                         ? accentGreen
                                         : .white.opacity(0.45))
                        .padding(6)
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

private struct NowPlayingPanel: View {
    let track: TrackInfo?
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            if let track = track {
                RemoteImage(url: track.albumArtURL, size: 170, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 5)
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                RemoteImage(url: nil, size: 170, cornerRadius: 12)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Nothing playing")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Controls directly below art — no Spacer pushing them down
            PlaybackControlsView(viewModel: viewModel)
                .padding(.top, 4)
        }
        .frame(width: 190)
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    @EnvironmentObject var stateController: StateController
    let result: SearchResult
    let isSelected: Bool

    private var isPlaying: Bool {
        if case .track(let track) = result {
            return track.uri == stateController.currentTrack?.id
        }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            switch result {
            case .track(let track):
                Image(systemName: "music.note")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isPlaying ? accentGreen : .white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                Text(track.durationString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))

            case .playlist(let playlist):
                if playlist.isLikedSongs {
                    LikedSongsArtwork(size: 32, cornerRadius: 5)
                } else {
                    RemoteImage(url: playlist.imageURL, size: 32, cornerRadius: 5)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let count = playlist.trackCount {
                        Text("\(count) tracks")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
        )
        .hoverHighlight(.background)
    }
}

// MARK: - Playlist Track Row

private struct PlaylistTrackRow: View {
    @EnvironmentObject var stateController: StateController
    let track: SpotifyTrack
    let index: Int
    let isSelected: Bool

    private var isPlaying: Bool {
        track.uri == stateController.currentTrack?.id
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isPlaying ? accentGreen : .white.opacity(0.25))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 18, alignment: .trailing)

            RemoteImage(url: track.albumArtURL, size: 32, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isPlaying ? accentGreen : .white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Text(track.durationString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .hoverHighlight(.background)
    }
}

// MARK: - Right Panel

private struct RightPanel: View {
    @ObservedObject var viewModel: HUDViewModel
    @State private var searchScroll = ScrollController()
    @State private var searchDragOffset: CGFloat? = nil
    @State private var searchScrollPosition = ScrollPosition(edge: .top)
    @State private var playlistScroll = ScrollController()
    @State private var playlistDragOffset: CGFloat? = nil
    @State private var playlistScrollPosition = ScrollPosition(edge: .top)

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

/// Holds live scroll metrics. Kept as a reference type (held via `@State`, not
/// `@StateObject`) so that per-frame metric updates only re-render the
/// `CustomScrollbar` that observes it — NOT the parent view that builds the
/// List. This prevents the list from being rebuilt on every scroll frame,
/// which is what made scrolling stutter/jump.
private final class ScrollController: ObservableObject {
    @Published var metrics = ScrollMetrics()
}

/// Hides the native (legacy) scroller of the enclosing NSScrollView so only the
/// custom thin scrollbar is visible. Placed as a zero-size row inside a List so
/// its backing view lives inside the scroll view's document hierarchy.
private struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.hideScroller(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.hideScroller(from: nsView) }
    }

    private static func hideScroller(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
    }
}

private struct CustomScrollbar: View {
    @ObservedObject var controller: ScrollController
    @Binding var dragOffset: CGFloat?

    private var metrics: ScrollMetrics { controller.metrics }

    var body: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let ratio = metrics.viewportHeight / max(1, metrics.contentHeight)
            let show = ratio < 1.0 && metrics.contentHeight > 0
            
            ZStack(alignment: .top) {
                // ── Wider hit area ───────────────────────────────────────────
                Color.white.opacity(0.001)
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { } 
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let thumbHeight = max(20, trackHeight * ratio)
                                let thumbRange = trackHeight - thumbHeight
                                let scrollRange = metrics.contentHeight - metrics.viewportHeight
                                
                                let deltaY = value.location.y - (thumbHeight / 2)
                                let newProgress = max(0, min(1, deltaY / max(1, thumbRange)))
                                dragOffset = newProgress * scrollRange
                            }
                            .onEnded { _ in
                                dragOffset = nil
                            }
                    )

                // ── Gutter ───────────────────────────────────────────────────
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 4)
                    .padding(.horizontal, 6)
                
                // ── Thumb ────────────────────────────────────────────────────
                if show {
                    let thumbHeight = max(20, trackHeight * ratio)
                    let scrollRange = metrics.contentHeight - metrics.viewportHeight
                    let thumbRange = trackHeight - thumbHeight
                    let progress = metrics.scrollOffset / max(1, scrollRange)
                    let thumbOffset = progress * thumbRange
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 4, height: thumbHeight)
                        .offset(y: thumbOffset)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 16)
        .opacity(metrics.viewportHeight / max(1, metrics.contentHeight) < 1.0 ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: metrics.viewportHeight / max(1, metrics.contentHeight) < 1.0)
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
                ProgressView().scaleEffect(0.7).padding(.vertical, 8)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if viewModel.displayedResults.isEmpty {
            Text(viewModel.searchText.isEmpty ? "Your playlists will appear here" : "No results")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.3))
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack(alignment: .trailing) {
                ScrollViewReader { proxy in
                    List {
                        ScrollerHider().frame(height: 0).plainListRow()
                        ForEach(0..<viewModel.displayedResults.count, id: \.self) { index in
                            let result = viewModel.displayedResults[index]
                            SearchResultRow(result: result, isSelected: index == viewModel.selectionIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.playResult(result) }
                                .plainListRow()
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 0)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .scrollPosition($searchScrollPosition)
                    .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                        ScrollMetrics(
                            contentHeight: geo.contentSize.height,
                            viewportHeight: geo.containerSize.height,
                            scrollOffset: geo.contentOffset.y
                        )
                    } action: { _, newValue in
                        searchScroll.metrics = newValue
                    }
                    .onChange(of: searchDragOffset) { _, newValue in
                        if let y = newValue { searchScrollPosition.scrollTo(y: y) }
                    }
                    .onChange(of: viewModel.selectionIndex) { _, idx in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }

                CustomScrollbar(controller: searchScroll, dragOffset: $searchDragOffset)
                    .padding(.vertical, 4)
                    .padding(.trailing, 2)
            }
        }
    }

    @ViewBuilder
    private var playlistDetailView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { viewModel.closePlaylist() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(8)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.bottom, 4)

            if viewModel.isLoadingTracks {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Spacer()
            } else if viewModel.displayedPlaylistTracks.isEmpty {
                Spacer()
                Text("No tracks found")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
            } else {
                ZStack(alignment: .trailing) {
                    ScrollViewReader { proxy in
                        List {
                            ScrollerHider().frame(height: 0).plainListRow()
                            ForEach(Array(viewModel.displayedPlaylistTracks.enumerated()), id: \.element.id) { index, track in
                                PlaylistTrackRow(track: track, index: index, isSelected: index == viewModel.selectionIndex)
                                    .onTapGesture {
                                        viewModel.playTrack(track)
                                    }
                                    .contentShape(Rectangle())
                                    .plainListRow()
                            }

                            if viewModel.tracksHasMore {
                                HStack {
                                    Spacer()
                                    ProgressView().scaleEffect(0.6)
                                    Spacer()
                                }
                                .frame(height: 36)
                                .onAppear { viewModel.loadMoreTracks() }
                                .plainListRow()
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 0)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .scrollPosition($playlistScrollPosition)
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                            ScrollMetrics(
                                contentHeight: geo.contentSize.height,
                                viewportHeight: geo.containerSize.height,
                                scrollOffset: geo.contentOffset.y
                            )
                        } action: { _, newValue in
                            playlistScroll.metrics = newValue
                            // Prefetch the next page as the user nears the bottom.
                            let distanceToBottom = newValue.contentHeight - (newValue.scrollOffset + newValue.viewportHeight)
                            if distanceToBottom < 600 {
                                viewModel.loadMoreTracks()
                            }
                        }
                        .onChange(of: playlistDragOffset) { _, newValue in
                            if let y = newValue { playlistScrollPosition.scrollTo(y: y) }
                        }
                        .onChange(of: viewModel.selectionIndex) { _, idx in
                            guard idx >= 0, idx < viewModel.displayedPlaylistTracks.count else { return }
                            let trackID = viewModel.displayedPlaylistTracks[idx].id
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(trackID, anchor: .center)
                            }
                        }
                    }

                    CustomScrollbar(controller: playlistScroll, dragOffset: $playlistDragOffset)
                        .padding(.vertical, 4)
                        .padding(.trailing, 2)
                }
            }
        }
    }
}

// MARK: - Settings View

private struct SettingsView: View {
    @ObservedObject var viewModel: HUDViewModel
    @EnvironmentObject var stateController: StateController
    @State private var scrollController = ScrollController()
    @State private var dragOffset: CGFloat? = nil
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            if let nsImage = BundleImageCache.image(resource: "logo", ext: "png") {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 32, height: 32)
                            }

                            Text("Settings")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.bottom, 4)

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

                        // Hotkey Customization
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hotkey Gesture")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Double-tap to toggle HUD")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            Menu {
                                ForEach(["Shift", "Control", "Option", "Command"], id: \.self) { mod in
                                    Button(mod) { viewModel.updateHotkeyModifier(mod) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(viewModel.hotkeyModifier)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10))
                                }
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .menuStyle(.button)
                        }
                        .padding(.vertical, 4)

                        Divider().background(Color.white.opacity(0.1))

                        // Service Info & Actions
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Active Service")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(stateController.activeService?.name ?? "None")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()

                            HStack(spacing: 10) {
                                Button(action: { viewModel.clearCache() }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Clear Cache")
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    .hoverHighlight(.background)
                                }
                                .buttonStyle(.plain)

                                Button(action: { viewModel.logout() }) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.red.opacity(0.7))
                                        .padding(10)
                                        .background(Color.red.opacity(0.15))
                                        .clipShape(Circle())
                                        .hoverHighlight()
                                }
                                .buttonStyle(.plain)
                                .help("Logout")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                    ScrollMetrics(
                        contentHeight: geo.contentSize.height,
                        viewportHeight: geo.containerSize.height,
                        scrollOffset: geo.contentOffset.y
                    )
                } action: { _, newValue in
                    scrollController.metrics = newValue
                }
                .onChange(of: dragOffset) { _, newValue in
                    if let y = newValue {
                        scrollPosition.scrollTo(y: y)
                    }
                }

                CustomScrollbar(controller: scrollController, dragOffset: $dragOffset)
                    .padding(.vertical, 4)
                    .padding(.trailing, 2)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("MusicOverlay v1.0.0")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
                
                Spacer()
                
                Button(action: { viewModel.quitApp() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                        Text("Quit App")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
                    .hoverHighlight(.background)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(size: 12))
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

private struct SettingSliderRow: View {
    let title: String
    let description: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text("\(Int((value / range.upperBound) * 100))%")
                    .font(.system(size: 12, weight: .medium))
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

public struct HUDView: View {
    @EnvironmentObject var stateController: StateController
    @StateObject private var viewModel: HUDViewModel
    @FocusState private var isSearchFocused: Bool

    // 0.5s for near-instant track updates
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    public init(stateController: StateController) {
        _viewModel = StateObject(wrappedValue: HUDViewModel(stateController: stateController))
    }

    private var miniPlayerView: some View {
        HStack(spacing: 12) {
            if let track = stateController.currentTrack {
                RemoteImage(url: track.albumArtURL, size: 40, cornerRadius: 8)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 240, height: 64)
        .background(WindowDragArea())
        .contentShape(Rectangle())
        .onTapGesture {
            WindowManager.shared.expandHUD()
        }
    }

    private var fullHUDView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // ── Search bar ──────────────────────────────────────────────
                HStack(spacing: 10) {
                    if viewModel.isSearching {
                        ProgressView().scaleEffect(0.65).frame(width: 16)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    TextField("Search playlists/songs…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)

                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.3))
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                )

                // ── Settings Button ─────────────────────────────────────────
                Button(action: { viewModel.toggleSettings() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(viewModel.showSettings ? .white : .white.opacity(0.6))
                        .offset(y: -1) // Move up one
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Main Content ────────────────────────────────────────────
            if viewModel.showSettings {
                SettingsView(viewModel: viewModel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HStack(alignment: .top, spacing: 0) {
                    NowPlayingPanel(track: stateController.currentTrack, viewModel: viewModel)
                        .padding(.leading, 16)
                        .padding(.trailing, 12)

                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 0.5)
                        .padding(.vertical, 12)

                    RightPanel(viewModel: viewModel)
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                }
                .padding(.bottom, 14)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 620, height: 420)
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
        .frame(width: viewModel.isMinimized ? 240 : 620, height: viewModel.isMinimized ? 64 : 420)
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
                        .padding(12)
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

private struct HoverHighlight: ViewModifier {
    let style: HoverStyle
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(style == .background && isHovering ? Color.white.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    func plainListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
