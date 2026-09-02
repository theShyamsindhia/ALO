// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WERAI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "alo", targets: ["WERAI"])
    ],
    targets: [
        .target(name: "WERAICore"),
        .target(name: "WERAISharedAudioClient"),
        .target(
            name: "ALOVirtualDisplay",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "WERAI",
            dependencies: ["WERAICore", "WERAISharedAudioClient", "ALOVirtualDisplay"],
            linkerSettings: [
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
            name: "WERAITests",
            dependencies: ["WERAICore", "WERAI"]
        )
    ]
)
