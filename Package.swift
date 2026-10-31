// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The echo canceller is a prebuilt static library (aec/build.sh). Linker
// search paths must be absolute, so derive them from this file's location.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let aecOut = "\(root)/aec/out"

let package = Package(
    name: "Stringer",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "stringer", targets: ["stringer"]),
        .executable(name: "StringerRecorder", targets: ["StringerRecorder"]),
        .executable(name: "StringerApp", targets: ["StringerApp"]),
        .executable(name: "stringer-title", targets: ["stringer-title"]),
        .executable(name: "aec-offline", targets: ["aec-offline"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0"),
    ],
    targets: [
        // C API over WebRTC AEC3: stringer_aec_create/_frame_size/_process/_destroy.
        .target(
            name: "CStringerAEC",
            path: "Sources/CStringerAEC",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(aecOut)/include/webrtc-audio-processing-2",
                    "-I\(aecOut)/include",
                    "-DWEBRTC_POSIX", "-DWEBRTC_MAC",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(aecOut)/lib", "-lstringer_webrtc"]),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Shared by every process: file names, WAV I/O, atomic writes, logging,
        // Core Audio device and process queries.
        .target(name: "StringerCore", path: "Sources/StringerCore"),
        // Capture only: the process tap, microphones, the shared timeline, AEC.
        .target(
            name: "CaptureKit",
            dependencies: ["StringerCore", "CStringerAEC"],
            path: "Sources/CaptureKit"
        ),
        // Meetings, settings, lifecycle and status. No speech models, so the
        // menu-bar app stays small.
        .target(
            name: "StringerKit",
            dependencies: ["StringerCore"],
            path: "Sources/StringerKit"
        ),
        // Speech recognition, diarization, live and final transcripts, titles.
        .target(
            name: "StringerPipeline",
            dependencies: [
                "StringerKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/StringerPipeline"
        ),
        .executableTarget(
            name: "stringer",
            dependencies: ["StringerKit", "StringerPipeline"],
            path: "Sources/stringer"
        ),
        .executableTarget(
            name: "StringerRecorder",
            dependencies: ["CaptureKit"],
            path: "Sources/StringerRecorder"
        ),
        .executableTarget(
            name: "StringerApp",
            dependencies: ["StringerKit"],
            path: "Sources/StringerApp"
        ),
        .executableTarget(
            name: "stringer-title",
            path: "Sources/stringer-title"
        ),
        .executableTarget(
            name: "aec-offline",
            dependencies: ["CaptureKit"],
            path: "Sources/aec-offline"
        ),
        .testTarget(
            name: "StringerTests",
            dependencies: ["StringerCore", "CaptureKit", "StringerKit", "StringerPipeline"],
            path: "Tests/StringerTests"
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
