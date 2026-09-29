// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "OrionCodeIntel",
    platforms: [
        // macOS 27 (Docs/18 M0): the FoundationModels OS 27 surface (`LanguageModelError`,
        // `SystemLanguageModel.variant`, the `LanguageModel` protocol) and Core AI are
        // @available(macOS 27.0, *) only, confirmed against the MacOSX27.0 SDK's swiftinterfaces.
        // String form because PackageDescription 6.2 has no `.v27` case. Every target stays in
        // Swift 5 language mode (`swiftLanguageModes: [.v5]` below) -- Phase 1 deliberately
        // avoided Swift 6 strict-concurrency churn on the shared pipeline context.
        .macOS("27.0")
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
        // The local model runtime (Docs/18 M2; the only one since M6 removed mlx-swift-lm and
        // swift-huggingface): `CoreAILanguageModel`, a FoundationModels `LanguageModel` over an
        // exported Core AI bundle. Pinned by revision, not the 0.2.0 tag -- 0.2.0 depends on
        // xgrammar `branch: main`, which SwiftPM rejects under a version pin (Docs/18 M1) -- and to
        // the exact commit `scripts/coreai/export-qwen3.sh` exports with, since the bundle format
        // and the runtime must match.
        .package(url: "https://github.com/apple/coreai-models", revision: "e7b24da85ea64a77d26324d7ce9607de9b955f57"),
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
                .product(name: "CoreAILM", package: "coreai-models"),
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
