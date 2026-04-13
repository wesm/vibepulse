// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibePulse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibePulse", targets: ["VibePulse"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "VibePulse",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
