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
        .target(name: "ObjCExceptionCatcher", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "AIMEVoiceHost", dependencies: ["AIMEVoice", "ObjCExceptionCatcher"],
                swiftSettings: strictSwift),
        .target(name: "AIMEVoiceSettings", dependencies: ["AIMEVoice"],
                resources: [.copy("Resources/VoiceConnectionTest.wav")], swiftSettings: strictSwift),
        .testTarget(name: "AIMEVoiceSettingsTests", dependencies: ["AIMEVoice", "AIMEVoiceSettings"], swiftSettings: strictSwift),
        // Two files cover rewrite features whose implementation is not in this tree
        // yet: undoing a rewrite by moving the caret back (VoiceRewriteRestoreTests)
        // and the focus-diagnosis reasons (FakeRewriteAccessibilityTests). Excluded so
        // the rest of the suite runs; drop the excludes when those are restored.
        .testTarget(name: "AIMEVoiceRewriteTests", dependencies: ["AIMEVoice", "AIMEVoiceHost"],
                swiftSettings: strictSwift),
        .testTarget(name: "AIMEVoiceTests", dependencies: ["AIMEVoice", "AIMEVoiceHost"], swiftSettings: strictSwift),
    ]
)
