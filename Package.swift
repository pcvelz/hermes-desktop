// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "HermesDesktop",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HermesPhoneKit",
            targets: ["HermesPhoneKit"]
        ),
        .executable(
            name: "HermesDesktop",
            targets: ["HermesDesktop"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .target(
            name: "HermesPhoneKit",
            dependencies: [
                "Citadel",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/HermesPhoneKit"
        ),
        .executableTarget(
            name: "HermesDesktop",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/HermesDesktop",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HermesDesktopTests",
            dependencies: ["HermesDesktop"],
            path: "Tests/HermesDesktopTests"
        )
    ]
)
