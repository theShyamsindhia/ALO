// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ALO",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "alo", targets: ["ALO"]),
        .library(name: "ALOCore", targets: ["ALOCore"]),
        .library(name: "ALOTiming", targets: ["ALOTiming"]),
        .library(name: "ALOIdentity", targets: ["ALOIdentity"]),
        .library(name: "ALONetworkUI", targets: ["ALONetworkUI"]),
        .library(name: "ALOAppModel", targets: ["ALOAppModel"]),
        .library(name: "ALORooms", targets: ["ALORooms"]),
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
        .target(name: "ALOTiming"),
        .target(name: "ALOIdentity"),
        .target(name: "ALONetworkUI"),
        .target(name: "ALOAppModel", dependencies: ["ALOIdentity", "ALORooms", "ALONetworking"]),
        .testTarget(name: "ALOIdentityTests", dependencies: ["ALOIdentity"]),
        .testTarget(name: "ALORoomsTests", dependencies: ["ALORooms", "ALOIdentity"]),
        .testTarget(name: "ALOAppModelTests", dependencies: ["ALOAppModel", "ALOIdentity", "ALORooms", "ALONetworking"]),
        .target(name: "ALORooms", dependencies: ["ALOCore", "ALOIdentity"]),
        .testTarget(name: "ALOTimingTests", dependencies: ["ALOTiming"]),
        .target(
            name: "ALOCore",
            dependencies: [
                "ALOTiming",
                .product(name: "Automerge", package: "automerge-swift")
            ]
        ),
        .target(
            name: "ALONotchRuntime",
            dependencies: [],
            path: "Vendor/DynamicNotch/DynamicNotch",
            exclude: [
                "Application/DynamicNotchApp.swift", "Application/MenuBarMenu.swift",
                "Features/Onboarding", "Features/Settings/Application/Views/General/SupportSettingsView.swift",
                "Shared/UI/Components/AnimateImage.swift", "Resources/LottieImage",
                "Application/Info.plist", "Application/DynamicNotch.entitlements",
                "Resources/Assets.xcassets", "Resources/Localization/Localizable.xcstrings",
                "Resources/Localization/InfoPlist.xcstrings", "Resources/Preview Content"
            ],
            resources: [
                .process("Resources/Generated"),
                .process("Resources/Sounds"), .copy("Resources/MediaRemoteAdapter")
            ],
            swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "ALOSharedAudioClient"),
        .target(name: "ALONetworking", dependencies: ["ALOCore", "ALOTiming", "ALOIdentity", "ALORooms"]),
        .target(name: "ALOAppleMedia", dependencies: ["ALOCore"]),
        .executableTarget(
            name: "ALO",
            dependencies: ["ALOCore", "ALOIdentity", "ALOAppModel", "ALONetworkUI", "ALORooms", "ALONetworking", "ALOAppleMedia", "ALOSharedAudioClient", "ALONotchRuntime"],
            exclude: ["Resources/AppIcons"],
            resources: [.copy("Resources/Breach")],
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
        .testTarget(name: "ALONotchRuntimeTests", dependencies: ["ALONotchRuntime"], swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
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
