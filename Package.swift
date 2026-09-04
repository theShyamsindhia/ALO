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
    dependencies: [
        .package(
            url: "https://github.com/automerge/automerge-swift.git",
            exact: "0.7.2"
        )
    ],
    targets: [
        .target(
            name: "WERAICore",
            dependencies: [
                .product(name: "Automerge", package: "automerge-swift")
            ]
        ),
        .target(name: "WERAISharedAudioClient"),
        .executableTarget(
            name: "WERAI",
            dependencies: ["WERAICore", "WERAISharedAudioClient"],
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
            name: "WERAITests",
            dependencies: ["WERAICore", "WERAI"]
        )
    ]
)
