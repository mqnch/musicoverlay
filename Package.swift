// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicOverlay",
    platforms: [
        .macOS(.v13) // Setting a modern baseline for SwiftUI and MusicKit
    ],
    targets: [
        .executableTarget(
            name: "MusicOverlay",
            path: "MusicOverlay",
            exclude: ["Info.plist"] // SwiftPM doesn't use the Info.plist directly for building the executable
        )
    ]
)
