// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VeeryMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VeeryMail", targets: ["VeeryMail"])
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
            dependencies: ["VeeryMailCore"],
            path: "Sources/VeeryMail"
        ),
        .testTarget(
            name: "VeeryMailTests",
            dependencies: ["VeeryMailCore"],
            path: "Tests/VeeryMailTests"
        ),
    ]
)
