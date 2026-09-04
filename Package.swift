// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ALO",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "alo", targets: ["ALO"])
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
        .executableTarget(
            name: "ALO",
            dependencies: ["ALOCore", "ALOSharedAudioClient"],
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
            dependencies: ["ALOCore", "ALO"]
        )
    ]
)
