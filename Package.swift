// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Replay",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "replay", targets: ["ReplayTool"]),
        .executable(name: "dispatch", targets: ["DispatchTool"]),
        .executable(name: "fingerprint", targets: ["FingerprintTool"]),
        .executable(name: "gate", targets: ["GateTool"]),
    ],
    targets: [
        // MARK: - Internal Libraries

        .target(
            name: "Yyjson",
            path: "yyjson",
            sources: ["src"],
            publicHeadersPath: "src"
        ),

        .target(
            name: "YyjsonCpp",
            dependencies: ["Yyjson"],
            path: "yyjson-cpp",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

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
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                // The math library is separate from the C library on Linux: std::ceil
                // (IpcPortSocket.cpp) is a call into it on x86_64, while aarch64 has an
                // instruction for it, so only the x86_64 link failed without this.
                .linkedLibrary("m", .when(platforms: [.linux])),
            ]
        ),

        .target(
            name: "Sandbox",
            dependencies: ["Common", "FileHelpers", "Yyjson", "YyjsonCpp"],
            path: "sandbox",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "Action",
            dependencies: ["Common"],
            path: "action",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "ReplayServer",
            path: "replay-server",
        ),

        .target(
            name: "FileTree",
            path: "file-tree",
            exclude: ["main.cpp"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        .target(
            name: "MedusaObjc",
            dependencies: ["Common", "FileTree", "GlobOverlap"],
            path: "medusa-objc",
            exclude: ["main.cpp"],
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
            // The ab_* files are #included by the crc32c_*.c wrappers. crc32c_variants.h is
            // internal; excluded, it stays out of a generated module map (callers declare
            // crc32_impl themselves, in FileHashing.h) and can still be #included.
            exclude: ["ab_sse_crc32c_v4s3x3k4096e.c", "ab_neon_eor3_crc32c_v9s3x2e_s3.c", "ab_neon_crc32c_v3s4x2e_v2.c", "generate-variants.sh", "crc32c_variants.h"],
            publicHeadersPath: "."
        ),

        .target(
            name: "FingerprintLib",
            dependencies: ["Common", "GlobCpp", "GlobOverlap", "Blake3", "FastCrc32", "Yyjson", "YyjsonCpp"],
            path: "fingerprint",
            exclude: ["main.cpp"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ]
        ),

        // MARK: - Tools

        .executableTarget(
            name: "ReplayTool",
            dependencies: ["Common", "Action", "ReplayServer", "FileTree", "MedusaObjc", "GlobCpp", "GlobOverlap", "Sandbox", "FingerprintLib"],
            path: "replay",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedLibrary("Foundation", .when(platforms: [.linux])),
                .linkedLibrary("dispatch", .when(platforms: [.linux])),
                .linkedLibrary("BlocksRuntime", .when(platforms: [.linux])),
            ]
        ),

        .executableTarget(
            name: "DispatchTool",
            dependencies: ["Common", "Action", "ReplayServer"],
            path: "dispatch",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedLibrary("Foundation", .when(platforms: [.linux])),
                .linkedLibrary("dispatch", .when(platforms: [.linux])),
                .linkedLibrary("BlocksRuntime", .when(platforms: [.linux])),
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
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedLibrary("objc", .when(platforms: [.macOS])),
                .linkedLibrary("Foundation", .when(platforms: [.linux])),
                .linkedLibrary("dispatch", .when(platforms: [.linux])),
                .linkedLibrary("BlocksRuntime", .when(platforms: [.linux])),
            ]
        ),

        .executableTarget(
            name: "GateTool",
            dependencies: ["Common", "FingerprintLib", "Sandbox", "FileHelpers", "Yyjson", "YyjsonCpp"],
            path: "gate",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation", .when(platforms: [.macOS])),
                .linkedLibrary("objc", .when(platforms: [.macOS])),
                .linkedLibrary("Foundation", .when(platforms: [.linux])),
                .linkedLibrary("dispatch", .when(platforms: [.linux])),
                .linkedLibrary("BlocksRuntime", .when(platforms: [.linux])),
            ]
        ),
    ]
)