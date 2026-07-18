// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AnotherFuckingNetworkingSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "AnotherFuckingNetworkingSDK",
            targets: ["AnotherFuckingNetworkingSDK"]
        ),
        .library(
            name: "AnotherFuckingNetworkingSDKTesting",
            targets: ["AnotherFuckingNetworkingSDKTesting"]
        ),
    ],
    targets: [
        .target(
            name: "AnotherFuckingNetworkingSDK",
            dependencies: []
        ),
        .target(
            name: "AnotherFuckingNetworkingSDKTesting",
            dependencies: ["AnotherFuckingNetworkingSDK"]
        ),
        .testTarget(
            name: "AnotherFuckingNetworkingSDKTests",
            dependencies: [
                "AnotherFuckingNetworkingSDK",
                "AnotherFuckingNetworkingSDKTesting"
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
