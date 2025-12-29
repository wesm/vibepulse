// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibePulse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibePulse", targets: ["VibePulse"]),
    ],
    targets: [
        .executableTarget(
            name: "VibePulse",
            path: "Sources/VibePulse",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "VibePulseTests",
            dependencies: ["VibePulse"],
            path: "Tests/VibePulseTests"
        ),
    ]
)
