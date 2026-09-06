// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "OrionCodeIntel",
    platforms: [
        // Bumped from .v14 for FoundationModels (Docs/12_phase3_mlx_agent.md M1's Depth
        // Model fallback) -- @available(macOS 26.0, *) is the framework's real floor,
        // confirmed against the installed SDK's swiftinterface, not vendor docs. `.v26`
        // requires PackageDescription 6.2, hence the tools-version bump above; every target
        // stays pinned to Swift 5 language mode below (`swiftLanguageModes: [.v5]`) so this
        // doesn't also silently switch the whole codebase to Swift 6's strict concurrency
        // checking -- Phase 1 deliberately avoided that churn on the shared pipeline context.
        .macOS(.v26)
    ],
    products: [
        .library(name: "OrionCodeIntel", targets: ["OrionCodeIntel"]),
        .executable(name: "orion-index", targets: ["orion-index"]),
        .library(name: "OrionAgent", targets: ["OrionAgent"]),
        .executable(name: "orion-agent", targets: ["orion-agent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        // Transitive via swift-tree-sitter; declared directly so we can `import TreeSitter`
        // for the C `TSInputEncodingUTF8` constant (UTF-8 byte offsets, not UTF-16).
        .package(url: "https://github.com/tree-sitter/tree-sitter", from: "0.25.0"),
        // Pinned exactly: 0.23.6's Package.swift lists both src/parser.c and src/scanner.c
        // unconditionally. 0.24+ switched to a broken `FileManager.fileExists("src/scanner.c")`
        // check that evaluates against the wrong CWD, so scanner.c is dropped and the link
        // fails with undefined `tree_sitter_python_external_scanner_*` symbols.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.30.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
        // Phase 3 (MLX Agent). Real product/target names verified against the actual tagged
        // Package.swift at 3.31.4, not vendor docs/AI summaries -- see
        // Docs/12_phase3_mlx_agent.md's M0 note. mlx-swift-lm's own manifest declares
        // swift-tools-version 6.1; that's independent of this root manifest's 5.10.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        // HuggingFace Hub download + tokenizer, wired to mlx-swift-lm via its MLXHuggingFace
        // macro integration (`#hubDownloader()` / `#huggingFaceTokenizerLoader()`) -- the
        // package's own recommended path for parity with its 2.x all-in-one API.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.10.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
    ],
    targets: [
        .target(
            name: "OrionCodeIntel",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            resources: [
                .copy("Symbols/Queries"),
            ]
        ),
        .executableTarget(
            name: "orion-index",
            dependencies: [
                "OrionCodeIntel",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "OrionCodeIntelTests",
            dependencies: ["OrionCodeIntel"],
            exclude: ["Snapshots"]   // golden files read by #filePath-relative path, not bundled
        ),
        .target(
            name: "OrionAgent",
            dependencies: [
                "OrionCodeIntel",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "orion-agent",
            dependencies: [
                "OrionAgent",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "OrionAgentTests",
            dependencies: ["OrionAgent"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
