// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicOverlay",
    platforms: [
        .macOS(.v14) // MusicLibraryRequest requires macOS 14+
    ],
    targets: [
        .executableTarget(
            name: "MusicOverlay",
            path: "MusicOverlay",
            exclude: ["Info.plist"], // SwiftPM doesn't use the Info.plist directly for building the executable
            resources: [.process("Resources")]
        )
    ]
)
