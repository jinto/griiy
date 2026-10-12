// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "griiy",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything but the window: arguments, git, the diff parser, the review, store and config.
        .target(name: "GriiyCore"),
        .executableTarget(
            name: "griiy",
            dependencies: ["GriiyCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "GriiyCoreTests", dependencies: ["GriiyCore"]),
    ]
)
