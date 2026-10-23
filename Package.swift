// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BreakBuddy",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BreakBuddy",
            path: "Sources/BreakBuddy",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
