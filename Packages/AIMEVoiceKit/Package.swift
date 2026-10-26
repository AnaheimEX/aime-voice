// swift-tools-version: 6.2
import PackageDescription

// Local voice input. It lives outside AIMEKit so that upstream merges never touch
// these declarations; none of these targets import AIMEKit modules.
let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "AIMEVoiceKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AIMEVoice", targets: ["AIMEVoice"]),
        .library(name: "AIMEVoiceHost", targets: ["AIMEVoiceHost"]),
        .library(name: "AIMEVoiceSettings", targets: ["AIMEVoiceSettings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "eb1e6628998e47022799d305b52c2680d3576801"),
        .package(url: "https://github.com/altic-dev/transcribe-cpp-swift.git", exact: "0.1.2"),
    ],
    targets: [
        .target(name: "FluidCaptureSupport", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AIMEVoice", dependencies: [
            "FluidCaptureSupport",
            .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS])),
            .product(name: "TranscribeCpp", package: "transcribe-cpp-swift"),
        ], swiftSettings: strictSwift),
        .target(name: "AIMEVoiceHost", dependencies: ["AIMEVoice"], swiftSettings: strictSwift),
        .target(name: "AIMEVoiceSettings", dependencies: ["AIMEVoice"],
                resources: [.copy("Resources/VoiceConnectionTest.wav")], swiftSettings: strictSwift),
        .testTarget(name: "AIMEVoiceSettingsTests", dependencies: ["AIMEVoice", "AIMEVoiceSettings"], swiftSettings: strictSwift),
        .testTarget(name: "AIMEVoiceRewriteTests", dependencies: ["AIMEVoiceHost"], swiftSettings: strictSwift),
    ]
)
