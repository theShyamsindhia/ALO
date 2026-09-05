// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ALO",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "alo", targets: ["ALO"]),
        .library(name: "ALOCore", targets: ["ALOCore"]),
        .library(name: "ALONetworking", targets: ["ALONetworking"]),
        .library(name: "ALOAppleMedia", targets: ["ALOAppleMedia"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/automerge/automerge-swift.git",
            exact: "0.7.2"
        )
    ],
    targets: [
        .target(
            name: "ALOCore",
            dependencies: [
                .product(name: "Automerge", package: "automerge-swift")
            ]
        ),
        .target(name: "ALOSharedAudioClient"),
        .target(name: "ALONetworking", dependencies: ["ALOCore"]),
        .target(name: "ALOAppleMedia", dependencies: ["ALOCore"]),
        .executableTarget(
            name: "ALO",
            dependencies: ["ALOCore", "ALONetworking", "ALOAppleMedia", "ALOSharedAudioClient"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("MediaPlayer"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "ALOTests",
            dependencies: ["ALOCore", "ALONetworking", "ALOAppleMedia", "ALO"]
        ),
        .testTarget(
            name: "ALONetworkingTests",
            dependencies: ["ALONetworking"]
        ),
        .testTarget(
            name: "ALOAppleMediaTests",
            dependencies: ["ALOAppleMedia"]
        )
    ]
)
