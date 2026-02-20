// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WindowManager",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WindowManager",
            dependencies: ["Yams"],
            path: "Sources/WindowManager"
        ),
    ]
)
