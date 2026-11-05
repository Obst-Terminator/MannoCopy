// swift-tools-version: 6.2
import PackageDescription

// Standalone regression checks; the macOS app continues to build in Xcode.
let package = Package(
    name: "MannoCopyChecks",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TransferCore", path: "MannoCopy",
                exclude: ["ContentView.swift", "MannoCopyApp.swift", "Info.plist", "Assets.xcassets"],
                sources: ["TransferCore.swift"]),
        .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
