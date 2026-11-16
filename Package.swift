// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VeeryMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VeeryMail", targets: ["VeeryMail"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        // Networking, models, sync, cache. No UI, no third-party dependencies.
        .target(
            name: "VeeryMailCore",
            path: "Sources/VeeryMailCore"
        ),
        // SwiftUI + small AppKit/WebKit bridges.
        .executableTarget(
            name: "VeeryMail",
            dependencies: ["VeeryMailCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/VeeryMail"
        ),
        .testTarget(
            name: "VeeryMailTests",
            dependencies: ["VeeryMailCore"],
            path: "Tests/VeeryMailTests"
        ),
    ]
)
