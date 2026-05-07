import SwiftUI

public struct HUDView: View {
    @EnvironmentObject var stateController: StateController
    @StateObject private var viewModel: HUDViewModel
    @FocusState private var isSearchFocused: Bool
    
    let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()
    
    public init(stateController: StateController) {
        _viewModel = StateObject(wrappedValue: HUDViewModel(stateController: stateController))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Pill-shaped Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search Playlists...", text: $viewModel.searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .focused($isSearchFocused)
                    .font(.system(size: 20, weight: .medium))
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(20)
            .padding()
            
            HStack(alignment: .top, spacing: 20) {
                // Left Panel: Current Track
                VStack(alignment: .leading, spacing: 10) {
                    Text("Now Playing")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    if let track = stateController.currentTrack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 150, height: 150)
                            .cornerRadius(10)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.largeTitle)
                                    .foregroundColor(.white.opacity(0.5))
                            )
                        
                        Text(track.title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .lineLimit(1)
                        
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Nothing playing")
                            .foregroundColor(.gray)
                    }
                    Spacer()
                }
                .frame(width: 200)
                
                Divider()
                
                // Right Panel: Playlists
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(Array(viewModel.filteredPlaylists.enumerated()), id: \.element.id) { index, playlist in
                                HStack {
                                    Text(playlist.name)
                                        .font(.system(size: 14))
                                        .foregroundColor(index == viewModel.selectionIndex ? .white : .primary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(index == viewModel.selectionIndex ? Color.blue.opacity(0.8) : Color.clear)
                                .cornerRadius(8)
                                .id(index)
                            }
                        }
                        .padding(.trailing)
                    }
                    .onChange(of: viewModel.selectionIndex) { _, newIndex in
                        withAnimation {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 600, height: 400)
        .background(Color.clear)
        .onAppear {
            isSearchFocused = true
        }
        .onReceive(timer) { _ in
            if let track = stateController.activeService?.getCurrentTrack() {
                stateController.currentTrack = track
            }
        }
        .background(
            Group {
                Button("") { viewModel.moveSelectionUp() }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { viewModel.moveSelectionDown() }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { 
                    viewModel.playSelected()
                    WindowManager.shared.toggleHUD()
                }.keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
        )
    }
}
