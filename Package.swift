// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CCBar",
            path: "Sources/CCBar",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CCBarTests",
            dependencies: ["CCBar"],
            path: "Tests/CCBarTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
