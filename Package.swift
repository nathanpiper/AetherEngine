// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AetherEngine",
            targets: ["AetherEngine"]
        ),
        // aetherctl is intentionally not exposed as a product. The target
        // uses Foundation.Process, which is unavailable on tvOS/iOS, so
        // exposing it would force SPM consumers to compile it on those
        // platforms. The target is preserved below so `swift build` on
        // macOS still produces the CLI for upstream development.
    ],
    dependencies: [
        // Minimal FFmpeg build (avcodec, avformat, avutil, swresample only).
        // No network stack — we use custom AVIO + URLSession for HTTP streams.
        // Resolved over Git rather than a local path so consumers (and
        // Xcode Cloud) can build without a sibling FFmpegBuild checkout.
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", branch: "main"),
        // GCDWebServer for the HLS-fMP4 loopback HTTP server. Our
        // handrolled BSD-socket impl triggered CFNetwork's loopback
        // I/O buffer pool to grow ~545 KB per segment served and never
        // free, OOM'ing long-form playback at ~15 min on Apple TV
        // (Instruments 2026-05-20: `VM: libnetwork` 66 MiB persistent /
        // 100% retention). DrHurt's reference Mac server that did NOT
        // leak is GCDWebServer-based, so swapping in the same library
        // on-device should produce the same no-leak behaviour.
        // yene's fork is the SPM-packaged variant of swisspol's
        // original library; tvOS 14+ supported, PrivacyInfo bundled.
        .package(url: "https://github.com/yene/GCDWebServer", from: "3.5.4"),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "FFmpegBuild", package: "FFmpegBuild"),
                .product(name: "GCDWebServer", package: "GCDWebServer"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "aetherctl",
            dependencies: ["AetherEngine"],
            path: "Sources/aetherctl"
        ),
    ]
)
