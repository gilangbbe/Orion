import Foundation

/// Derives `tested_by` edges (source = test symbol, target = production symbol) from the
/// call/reference/import edges already in the graph. Heuristic, so every edge is
/// `provenance = "heuristic:test_reference"` with a modest confidence.
public struct TestMapper {
    public let repositoryId: String
    public let commitHash: String
    public let runId: String

    public init(repositoryId: String, commitHash: String, runId: String) {
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
    }

    public func build(
        files: [FileRecord], symbols: [SymbolRecord], relationships: [RelationshipRecord]
    ) -> [RelationshipRecord] {
        let fileById = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let symbolById = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })

        func isProduction(_ symbolId: String?) -> SymbolRecord? {
            guard let id = symbolId, let sym = symbolById[id],
                  let file = fileById[sym.fileId], !file.isTest else { return nil }
            return sym
        }
        func testFileStem(_ path: String) -> String {
            var name = (path as NSString).lastPathComponent
            if name.hasSuffix(".py") { name.removeLast(3) }
            if name.hasPrefix("test_") { name.removeFirst(5) }
            if name.hasSuffix("_test") { name.removeLast(5) }
            return name
        }

        // test symbols that can originate a mapping
        let testSymbolIds = Set(symbols.compactMap { sym -> String? in
            guard let file = fileById[sym.fileId] else { return nil }
            return TestDetector.isTestSymbol(
                name: sym.name, kind: sym.kind, decorators: sym.decorators, fileIsTest: file.isTest
            ) ? sym.id : nil
        })
        let testModuleIds = Set(symbols.filter {
            ($0.kind == "module" || $0.kind == "package") && (fileById[$0.fileId]?.isTest ?? false)
        }.map { $0.id })

        // best tier per (testSymbol, productionSymbol)
        var best: [String: (source: SymbolRecord, target: SymbolRecord, tier: ConfidenceTier)] = [:]
        func consider(source: SymbolRecord, target: SymbolRecord, tier: ConfidenceTier) {
            let key = "\(source.id)\u{1f}\(target.id)"
            if let existing = best[key], existing.tier.score >= tier.score { return }
            best[key] = (source, target, tier)
        }

        for rel in relationships {
            switch rel.relationshipType {
            case "calls", "references":
                guard let src = rel.sourceSymbolId, testSymbolIds.contains(src),
                      let source = symbolById[src], let target = isProduction(rel.targetSymbolId)
                else { continue }
                // name-match boost: tests/test_foo.py <-> .../foo.py
                let stem = testFileStem(fileById[source.fileId]?.path ?? "")
                let targetStem = (
                    (fileById[target.fileId]?.path ?? "") as NSString
                ).lastPathComponent.replacingOccurrences(of: ".py", with: "")
                let tier: ConfidenceTier =
                    rel.relationshipType == "calls"
                        ? (stem == targetStem ? .high : .medium)
                        : .low
                consider(source: source, target: target, tier: tier)

            case "imports":
                guard let src = rel.sourceSymbolId, testModuleIds.contains(src),
                      let source = symbolById[src], let target = isProduction(rel.targetSymbolId),
                      target.kind == "module" || target.kind == "package"
                else { continue }
                consider(source: source, target: target, tier: .low)

            default:
                continue
            }
        }

        return best.values
            .map { entry in
                let id = DeterministicID.relationship(
                    repositoryId: repositoryId, commitHash: commitHash,
                    type: "tested_by", source: entry.source.id, target: entry.target.id, site: ""
                )
                return RelationshipRecord(
                    id: id, repositoryId: repositoryId, commitHash: commitHash, runId: runId,
                    relationshipType: RelationshipType.testedBy.rawValue,
                    sourceSymbolId: entry.source.id, targetSymbolId: entry.target.id,
                    externalDependencyId: nil, sourceRef: nil, targetRef: nil,
                    provenance: "heuristic:test_reference", confidence: entry.tier.score,
                    confidenceTier: entry.tier.rawValue, resolved: true,
                    epistemicType: EpistemicType.fact.rawValue, siteFileId: nil,
                    siteStartLine: nil, siteStartCol: nil, siteEndLine: nil, siteEndCol: nil
                )
            }
            .sorted { $0.id < $1.id }
    }
}
