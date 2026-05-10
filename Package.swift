// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Replay",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "replay", targets: ["ReplayTool"]),
        .executable(name: "dispatch", targets: ["DispatchTool"]),
        .executable(name: "fingerprint", targets: ["FingerprintTool"]),
        .executable(name: "gate", targets: ["GateTool"]),
    ],
    targets: [
        // MARK: - Internal Libraries

        .target(
            name: "GlobCpp",
            path: "glob-cpp"
        ),

        .target(
            name: "GlobOverlap",
            dependencies: ["GlobCpp"],
            path: "glob-overlap",
            exclude: ["globoverlap.cpp"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "FileHelpers",
            dependencies: ["GlobOverlap"],
            path: "file-helpers",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "Common",
            path: "common",
        ),

        .target(
            name: "Sandbox",
            dependencies: ["Common", "FileHelpers"],
            path: "sandbox",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "Action",
            dependencies: ["Common"],
            path: "action",
        ),

        .target(
            name: "ReplayServer",
            path: "replay-server",
        ),

        .target(
            name: "FileTree",
            path: "file-tree",
            exclude: ["main.m"],
        ),

        .target(
            name: "MedusaObjc",
            dependencies: ["Common", "FileTree", "GlobOverlap"],
            path: "medusa-objc",
            exclude: ["main.mm"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "Blake3",
            path: "blake3",
            exclude: ["blake3_sse2.c", "blake3_neon.c"],
            publicHeadersPath: ".",
            cSettings: [
                .define("BLAKE3_NO_SSE41", to: "1"),
                .define("BLAKE3_NO_AVX512", to: "1"),
                .define("BLAKE3_NO_AVX2", to: "1"),
            ]
        ),

        .target(
            name: "FastCrc32",
            path: "fast-crc32",
            exclude: ["ab_sse_crc32c_v4s3x3k4096e.c", "ab_neon_eor3_crc32c_v9s3x2e_s3.c"],
            publicHeadersPath: "."
        ),

        .target(
            name: "FingerprintLib",
            dependencies: ["GlobCpp", "GlobOverlap", "Blake3", "FastCrc32"],
            path: "fingerprint",
            exclude: ["main.cpp"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        // MARK: - Tools

        .executableTarget(
            name: "ReplayTool",
            dependencies: ["Common", "Action", "ReplayServer", "FileTree", "MedusaObjc", "GlobCpp", "GlobOverlap", "Sandbox"],
            path: "replay",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),

        .executableTarget(
            name: "DispatchTool",
            dependencies: ["Common", "Action", "ReplayServer"],
            path: "dispatch",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),

        .executableTarget(
            name: "FingerprintTool",
            dependencies: ["Common", "FingerprintLib"],
            path: "fingerprint",
            sources: ["main.cpp"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedLibrary("objc"),
            ]
        ),

        .executableTarget(
            name: "GateTool",
            dependencies: ["Common", "FingerprintLib", "Sandbox", "FileHelpers"],
            path: "gate",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedLibrary("objc"),
            ]
        ),
    ]
)