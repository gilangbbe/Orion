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
        .macOS("27.0"),
        // iOS 27 (Docs/19 M1): the iOS companion links `OrionCore` (and `OrionAgent` for
        // on-device Ask/Learn). The analysis targets still only make sense on the Mac -- they
        // shell out to git/npx -- but declaring the platform lets SwiftPM resolve GRDB & co. at
        // the right iOS floor for the targets that do build there.
        .iOS("27.0"),
    ],
    products: [
        .library(name: "OrionCore", targets: ["OrionCore"]),
        .library(name: "OrionSync", targets: ["OrionSync"]),
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
        // The portable half of the old `OrionCodeIntel` (Docs/19 M1): the persisted Codebase
        // Model (records, `Store`, migrations), its queries, the semantic/revision layer and the
        // teaching logic. GRDB only -- no tree-sitter, no subprocesses -- so it builds for iOS.
        // `OrionCodeIntel` re-exports it (`@_exported import OrionCore`), so existing
        // `import OrionCodeIntel` callers compile unchanged.
        .target(
            name: "OrionCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // Knowledge snapshots over CloudKit (Docs/19 M5): the Mac publishes, the iOS companion
        // receives. Both sides use `CKSyncEngine` on the user's private database; the record
        // mapping and persisted sync state are plain code, so they're unit-tested without iCloud.
        .target(
            name: "OrionSync",
            dependencies: ["OrionCore"]
        ),
        .testTarget(
            name: "OrionSyncTests",
            dependencies: ["OrionSync", "OrionCore"]
        ),
        .target(
            name: "OrionCodeIntel",
            dependencies: [
                "OrionCore",
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
            dependencies: ["OrionCodeIntel", "OrionCore"],
            exclude: ["Snapshots"]   // golden files read by #filePath-relative path, not bundled
        ),
        .target(
            name: "OrionAgent",
            dependencies: [
                // `OrionCore`, not `OrionCodeIntel` (Docs/19 M1): the agent only reads the persisted
                // model, so it builds for iOS without tree-sitter or the subprocess-driven analysis.
                "OrionCore",
                // Mac only (Docs/19 M1): on iOS every model call goes to the on-device system
                // model, so the Core AI runtime (and xgrammar) would be dead weight in the app.
                .product(name: "CoreAILM", package: "coreai-models", condition: .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "orion-agent",
            dependencies: [
                "OrionAgent",
                "OrionCodeIntel",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "OrionAgentTests",
            dependencies: ["OrionAgent", "OrionCore", "OrionCodeIntel"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
