// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "CCBar",
            path: "Sources/CCBar",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
