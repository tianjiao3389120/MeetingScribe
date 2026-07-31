// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            path: "MeetingScribe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
