// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OrionCodeIntel",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OrionCodeIntel", targets: ["OrionCodeIntel"]),
        .executable(name: "orion-index", targets: ["orion-index"]),
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
    ]
)
