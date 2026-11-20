// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MacAudioOo",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "MacAudioOo",
            path: "Sources/MacAudioOo",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "MacAudioOoTests",
            dependencies: ["MacAudioOo"],
            path: "Tests/MacAudioOoTests"
        ),
    ]
)
