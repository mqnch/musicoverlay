import SwiftUI

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
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = NSImage(data: data) else { return }
        image = loaded
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
                .accentColor(Color(red: 0.18, green: 0.8, blue: 0.44))
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
            HStack(spacing: 22) {
                Button(action: { viewModel.previousTrack() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Previous")

                Button(action: { viewModel.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: viewModel.isPlaying ? 0 : 1)
                    }
                }
                .buttonStyle(.plain)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Button(action: { viewModel.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Next")
            }
            .frame(maxWidth: .infinity)

            // ── Row 2: Shuffle / Repeat ──────────────────────────────────
            HStack(spacing: 32) {
                Button(action: { viewModel.toggleShuffle() }) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.isShuffled
                                         ? Color(red: 0.18, green: 0.8, blue: 0.44)
                                         : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Shuffle")

                Button(action: { viewModel.cycleRepeat() }) {
                    Image(systemName: viewModel.repeatMode.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.repeatMode.isActive
                                         ? Color(red: 0.18, green: 0.8, blue: 0.44)
                                         : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Repeat")
            }
            .frame(maxWidth: .infinity)

            // ── Volume slider ────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                Slider(
                    value: $viewModel.volume,
                    in: 0...100,
                    onEditingChanged: { editing in
                        if !editing { viewModel.commitVolume() }
                    }
                )
                .accentColor(.white.opacity(0.6))
                .controlSize(.mini)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
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
    let result: SearchResult
    let isSelected: Bool

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
                        .foregroundColor(.white)
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
                RemoteImage(url: playlist.imageURL, size: 32, cornerRadius: 5)

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
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
        )
    }
}

// MARK: - Playlist Track Row

private struct PlaylistTrackRow: View {
    let track: SpotifyTrack
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
                .frame(width: 18, alignment: .trailing)

            RemoteImage(url: track.albumArtURL, size: 32, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
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
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Right Panel

private struct RightPanel: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        if viewModel.selectedPlaylist != nil {
            playlistDetailView
        } else {
            searchResultsView
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if viewModel.isSearching {
                        HStack {
                            ProgressView().scaleEffect(0.7).padding(.vertical, 8)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                    } else if viewModel.displayedResults.isEmpty {
                        Text(viewModel.searchText.isEmpty ? "Your playlists will appear here" : "No results")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(viewModel.displayedResults.enumerated()), id: \.element.id) { index, result in
                            SearchResultRow(result: result, isSelected: index == viewModel.selectionIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.playResult(result) }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .onChange(of: viewModel.selectionIndex) { _, newIndex in
                withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var playlistDetailView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { viewModel.closePlaylist() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                if let playlist = viewModel.selectedPlaylist {
                    RemoteImage(url: playlist.imageURL, size: 22, cornerRadius: 3)
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
            } else if viewModel.playlistTracks.isEmpty {
                Spacer()
                Text("No tracks found")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(viewModel.playlistTracks.enumerated()), id: \.element.id) { index, track in
                            PlaylistTrackRow(track: track, index: index)
                                .onTapGesture {
                                    viewModel.playTrack(track)
                                    WindowManager.shared.toggleHUD()
                                }
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
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

    public var body: some View {
        VStack(spacing: 0) {
            // ── Search bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                if viewModel.isSearching {
                    ProgressView().scaleEffect(0.65).frame(width: 16)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }

                TextField("Search songs & playlists…", text: $viewModel.searchText)
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
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Main panels ─────────────────────────────────────────────
            HStack(alignment: .top, spacing: 0) {
                NowPlayingPanel(track: stateController.currentTrack, viewModel: viewModel)
                    .padding(.leading, 16)
                    .padding(.trailing, 12)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 4)

                RightPanel(viewModel: viewModel)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
            }
            .padding(.bottom, 14)
        }
        .frame(width: 620, height: 420)
        .background(Color.clear)
        .onAppear {
            isSearchFocused = true
            // Register this view's model with the keyboard monitor
            WindowManager.shared.activeViewModel = viewModel
        }
        .onReceive(NotificationCenter.default.publisher(for: .hudDidShow)) { _ in
            // Re-focus search field once the panel is truly key
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onReceive(timer) { _ in viewModel.refreshNowPlaying() }
        .background(
            Group {
                Button("") { viewModel.moveSelectionUp()   }.keyboardShortcut(.upArrow,   modifiers: [])
                Button("") { viewModel.moveSelectionDown() }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") {
                    if viewModel.selectedPlaylist != nil { viewModel.closePlaylist() }
                    else { viewModel.activateSelection() }
                }.keyboardShortcut(.return, modifiers: [])
                Button("") {
                    if viewModel.selectedPlaylist != nil { viewModel.closePlaylist() }
                }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
        )
    }
}
