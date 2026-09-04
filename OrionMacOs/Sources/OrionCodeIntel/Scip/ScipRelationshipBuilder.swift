import Foundation

/// Turns a SCIP index into Orion relationship edges: `extends` / `implements` from
/// `SymbolInformation.relationships`, and `calls` / `references` from reference occurrences
/// attributed to their enclosing symbol.
///
/// `scip-python` emits no `syntax_kind` and no write-access roles, so Phase 1 does not try
/// to distinguish a constructor call from a type annotation (both land as `references` on a
/// class), and `reads` / `writes` on attributes are out of scope here.
public struct ScipRelationshipBuilder {
    public let repositoryId: String
    public let commitHash: String
    public let runId: String
    public let maxSitesPerPair: Int

    public init(
        repositoryId: String, commitHash: String, runId: String, maxSitesPerPair: Int = 20
    ) {
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.maxSitesPerPair = maxSitesPerPair
    }

    // SCIP SymbolRole bitmask
    private static let roleDefinition: Int32 = 0x1
    private static let roleImport: Int32 = 0x2
    private static let roleWrite: Int32 = 0x4
    private static let roleRead: Int32 = 0x8

    private static let protocolLeaves: Set<String> = ["Protocol", "ABC", "ABCMeta"]

    public struct Output {
        public var relationships: [RelationshipRecord] = []
        public var unresolvedExternalCount = 0
    }

    public func build(
        index: Scip_Index, joiner: SymbolJoiner, files: [FileRecord]
    ) -> Output {
        var out = Output()
        var seen = Set<String>()
        let fileIdByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.id) })

        // --- inheritance ---------------------------------------------------------
        var inheritancePairs = Set<String>()
        let allSymbolInfos = index.documents.flatMap { $0.symbols } + index.externalSymbols
        for info in allSymbolInfos {
            guard let subScip = ScipSymbol(info.symbol), subScip.leafKind == .type,
                  let subAnchor = joiner.anchor(for: subScip)
            else { continue }
            for rel in info.relationships where rel.isImplementation {
                guard let baseScip = ScipSymbol(rel.symbol) else { continue }
                guard baseScip.leafKind == .type else { continue }   // class↔class only
                let baseAnchor = joiner.anchor(for: baseScip)

                let type: RelationshipType
                let tier: ConfidenceTier
                let resolved: Bool
                if baseAnchor != nil {
                    type = .extends; tier = .high; resolved = true
                } else if let leaf = baseScip.leafName, Self.protocolLeaves.contains(leaf) {
                    type = .implements; tier = .medium; resolved = false
                } else {
                    type = .extends; tier = .low; resolved = false
                }

                let targetKey = baseAnchor ?? baseScip.inFileDotted
                let id = DeterministicID.relationship(
                    repositoryId: repositoryId, commitHash: commitHash,
                    type: type.rawValue, source: subAnchor, target: targetKey, site: ""
                )
                guard seen.insert(id).inserted else { continue }
                inheritancePairs.insert("\(subAnchor)\u{1f}\(targetKey)")

                out.relationships.append(RelationshipRecord(
                    id: id, repositoryId: repositoryId, commitHash: commitHash, runId: runId,
                    relationshipType: type.rawValue,
                    sourceSymbolId: joiner.symbol(forAnchor: subAnchor)?.id,
                    targetSymbolId: baseAnchor.flatMap { joiner.symbol(forAnchor: $0)?.id },
                    externalDependencyId: nil,
                    sourceRef: nil, targetRef: baseAnchor == nil ? baseScip.inFileDotted : nil,
                    provenance: "scip", confidence: tier.score, confidenceTier: tier.rawValue,
                    resolved: resolved, epistemicType: EpistemicType.fact.rawValue,
                    siteFileId: nil, siteStartLine: nil, siteStartCol: nil,
                    siteEndLine: nil, siteEndCol: nil
                ))
            }
        }

        // --- calls / references ----------------------------------------------------
        var pairSiteCount: [String: Int] = [:]
        for doc in index.documents {
            guard let siteFileId = fileIdByPath[doc.relativePath] else { continue }
            for occ in doc.occurrences {
                let roles = occ.symbolRoles
                if roles & Self.roleDefinition != 0 || roles & Self.roleImport != 0 { continue }
                guard occ.range.count >= 3, let targetScip = ScipSymbol(occ.symbol),
                      !targetScip.isLocal,
                      let targetAnchor = joiner.anchor(for: targetScip),
                      let targetSym = joiner.symbol(forAnchor: targetAnchor)
                else {
                    if ScipSymbol(occ.symbol)?.isLocal == false { out.unresolvedExternalCount += 1 }
                    continue
                }

                let startLine = Int(occ.range[0]) + 1
                let (endLine, startCol, endCol) = decodeRange(occ.range)
                guard let src = joiner.enclosingSymbol(relPath: doc.relativePath, line: startLine),
                      src.id != targetSym.id
                else { continue }

                let type: RelationshipType
                switch targetSym.kind {
                case "function", "method", "property":
                    type = .calls
                case "class":
                    if inheritancePairs.contains("\(src.anchor)\u{1f}\(targetAnchor)") { continue }
                    type = .references
                default:
                    continue   // variable/constant reads/writes not available from scip-python
                }

                let pairKey = "\(src.id)\u{1f}\(targetSym.id)\u{1f}\(type.rawValue)"
                let n = pairSiteCount[pairKey, default: 0]
                if n >= maxSitesPerPair { continue }
                pairSiteCount[pairKey] = n + 1

                let id = DeterministicID.relationship(
                    repositoryId: repositoryId, commitHash: commitHash, type: type.rawValue,
                    source: src.id, target: targetSym.id, site: "\(startLine):\(startCol)"
                )
                guard seen.insert(id).inserted else { continue }

                out.relationships.append(RelationshipRecord(
                    id: id, repositoryId: repositoryId, commitHash: commitHash, runId: runId,
                    relationshipType: type.rawValue, sourceSymbolId: src.id,
                    targetSymbolId: targetSym.id, externalDependencyId: nil,
                    sourceRef: nil, targetRef: nil, provenance: "scip",
                    confidence: ConfidenceTier.high.score,
                    confidenceTier: ConfidenceTier.high.rawValue, resolved: true,
                    epistemicType: EpistemicType.fact.rawValue, siteFileId: siteFileId,
                    siteStartLine: startLine, siteStartCol: startCol,
                    siteEndLine: endLine, siteEndCol: endCol
                ))
            }
        }
        return out
    }

    /// SCIP range is `[startLine, startChar, endLine, endChar]` or `[startLine, startChar,
    /// endChar]` (single line). Char offsets are UTF-16 (Pyright); stored +1 as an
    /// approximate column, line numbers are exact.
    private func decodeRange(_ r: [Int32]) -> (endLine: Int, startCol: Int, endCol: Int) {
        let startCol = Int(r[1]) + 1
        if r.count >= 4 {
            return (Int(r[2]) + 1, startCol, Int(r[3]) + 1)
        }
        return (Int(r[0]) + 1, startCol, Int(r[2]) + 1)
    }
}
