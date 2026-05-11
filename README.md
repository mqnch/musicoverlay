# MusicOverlay

A keyboard-driven macOS HUD for controlling music without switching apps. Summon it with a global hotkey, search your playlists, and get back to work.

Supports Spotify and Apple Music.

## Features

- Global hotkey (Double-Shift) to toggle the HUD from any app
- Fuzzy search across playlists with keyboard navigation
- Now Playing view with album art, track info, and playback controls
- Mini Player mode that stays on top and out of the way
- Spotify integration via PKCE OAuth with your own Client ID
- Apple Music integration via AppleScript and MusicKit
- Zero-latency transport controls (play, pause, skip) over local AppleScript

## Requirements

- macOS 13 or later
- Xcode 15 or later
- A Spotify Developer account (if using Spotify)

## Setup

**Apple Music** works out of the box. Grant the app Automation permission when prompted.

**Spotify** requires a few extra steps:

1. Go to [developer.spotify.com](https://developer.spotify.com) and create an app.
2. Add `http://127.0.0.1:8082/callback` as a Redirect URI in your app's settings.
3. Copy your Client ID.
4. Open MusicOverlay, go to Settings, and paste the Client ID. Authenticate when prompted.

## Building

Open `Package.swift` in Xcode or build from the command line:

```bash
swift build
```

To run:

```bash
swift run
```

## Usage

Press Shift twice to open the HUD. Type to filter playlists. Use arrow keys to navigate, Return to play the selected playlist, and Escape to dismiss.

The window minimizes to a Mini Player when you switch focus. Drag it anywhere on screen — its position is saved across sessions.

Keybinds and visibility can be edited in settings.

## Privacy

Spotify credentials are stored in the system Keychain. No data is sent anywhere except the official Spotify API.
