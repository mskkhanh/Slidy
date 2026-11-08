// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Slidy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ArchiveBridge", linkerSettings: [.linkedLibrary("archive.2")]),
        .executableTarget(name: "Slidy", dependencies: ["ArchiveBridge"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
