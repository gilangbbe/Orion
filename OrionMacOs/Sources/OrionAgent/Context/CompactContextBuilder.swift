import Foundation
import OrionCore

/// Primes a small-window model (the iPhone's system model: 4,096 tokens, Docs/19 M0) with only the
/// part of the Codebase Model the question is about (Docs/19 M6). `ContextBuilder` embeds the
/// export files wholesale -- ~10K tokens, fine for Qwen3's 40K window, three times the phone's.
///
/// Retrieval is lexical and deterministic: the question's words (identifiers split on `_` and
/// case) are matched against
/// - the latest architecture investigation's **components**,
/// - the run's **claims** -- never `CONTRADICTED` ones, which the consistency check already
///   rejected (48 of Starlette's 108),
/// - **symbols** whose name contains a code-like word from the question,
///
/// ranked by overlap, and packed greedily into `budgetTokens`. The repository overview, a
/// component-scoped session's focus, and the previous turn always come first. The caller passes
/// the real token counter (`SystemLanguageModel.tokenCount`); packing estimates by characters
/// and the result is then checked and trimmed against the real count.
public enum CompactContextBuilder {
    public enum Section: Int, Comparable, Sendable {
        case overview, focus, conversation, components, symbols, claims

        public static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }

        var header: String {
            switch self {
            case .overview: return "Repository"
            case .focus: return "This conversation is about one component"
            case .conversation: return "Earlier in this conversation"
            case .components: return "Components (an earlier investigation's interpretation)"
            case .symbols: return "Symbols matching the question (facts from static analysis)"
            case .claims: return "Claims (checked against the code)"
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public let section: Section
        public let text: String
        /// Higher packs first. The overview, focus and conversation are always included.
        public let score: Double

        var isMandatory: Bool { section == .overview || section == .focus || section == .conversation }
    }

    /// Characters per token for packing estimates -- Docs/19 M0 measured 4.4-5.0 on Orion
    /// context; 4.0 errs on the side of fitting.
    static let charsPerToken = 4.0

    // MARK: - Retrieval

    public static func candidates(
        store: Store, run: AnalysisRunRecord, question: String, priorTurns: [AskSessionPriorTurn] = [],
        componentContext: String? = nil
    ) throws -> [Item] {
        let terms = Self.terms(question)
        var items: [Item] = []

        let investigations = try store.investigations(runId: run.id)
        let architecture = investigations.last { $0.question == InvestigationRecord.architectureQuestionMarker }
        let components = try architecture.map { try store.components(investigationId: $0.id) } ?? []
        let repository = try store.repository(id: run.repositoryId)
        items.append(Item(
            section: .overview,
            text: "\(repository?.localPath ?? "repository") at commit \(run.commitHash.prefix(12)): "
                + "\(run.fileCount) files, \(run.symbolCount) symbols"
                + (components.isEmpty ? "; no architecture model yet." : "; \(components.count) components."),
            score: .infinity))

        if let componentContext, !componentContext.isEmpty {
            items.append(Item(section: .focus, text: truncated(componentContext, 1_200), score: .infinity))
        }
        if let last = priorTurns.last {
            items.append(Item(
                section: .conversation,
                text: "Q: \(truncated(last.question, 300))\nA: \(truncated(last.answerText, 500))",
                score: .infinity))
        }

        for component in components {
            let text = "\(component.name) (\(component.architecturalRole ?? "component")): "
                + truncated(component.description ?? "", 240)
            // Every component gets a small floor so a vague question still sees the map.
            items.append(Item(section: .components, text: text, score: 0.5 + overlap(terms, text)))
        }

        for investigation in investigations {
            for claim in try store.claims(investigationId: investigation.id)
            where claim.claimType != EpistemicType.contradicted.rawValue && claim.claimType != EpistemicType.unknown.rawValue {
                let score = overlap(terms, claim.statement)
                guard score > 0 else { continue }
                let anchors = try store.evidence(claimIds: [claim.id]).prefix(2).map(\.anchor)
                items.append(Item(
                    section: .claims,
                    text: truncated(claim.statement, 280) + (anchors.isEmpty ? "" : " [\(anchors.joined(separator: ", "))]"),
                    score: score))
            }
        }

        let engine = QueryEngine(store.db)
        var seenAnchors: Set<String> = []
        for word in codeWords(question) {
            for hit in try engine.findSymbols(matching: word, commit: run.commitHash, limit: 4)
            where seenAnchors.insert(hit.anchor).inserted {
                let symbol = try store.symbol(runId: run.id, anchor: hit.anchor)
                let detail = symbol?.signature ?? symbol?.docstring?.split(separator: "\n").first.map(String.init) ?? ""
                items.append(Item(
                    section: .symbols,
                    text: "\(hit.anchor) (\(hit.kind)) \(hit.file):\(hit.startLine)-\(hit.endLine)"
                        + (detail.isEmpty ? "" : " — \(truncated(detail, 160))"),
                    // A symbol named in the question is the strongest signal there is.
                    score: 3 + overlap(terms, hit.anchor)))
            }
        }
        return items
    }

    // MARK: - Packing

    /// The highest-scoring items that fit `budgetTokens` (estimated), rendered grouped by section.
    public static func pack(_ items: [Item], budgetTokens: Int) -> String {
        let ordered = items.filter(\.isMandatory) + items.filter { !$0.isMandatory }.sorted { $0.score > $1.score }
        var chosen: [Item] = []
        var used = 0
        for item in ordered {
            let cost = estimate(item.text) + 2
            if !item.isMandatory, used + cost > budgetTokens { continue }
            chosen.append(item)
            used += cost
        }
        return render(chosen)
    }

    static func render(_ items: [Item]) -> String {
        Dictionary(grouping: items, by: \.section)
            .sorted { $0.key < $1.key }
            .map { section, items in
                section == .overview
                    ? "\(section.header): \(items[0].text)"
                    : "\(section.header):\n" + items.map { "- \($0.text)" }.joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    /// Packs, then checks with the real counter and shrinks the budget until it fits (at most
    /// three tries; the estimate is usually already under).
    public static func build(
        store: Store, run: AnalysisRunRecord, question: String, priorTurns: [AskSessionPriorTurn] = [],
        componentContext: String? = nil, budgetTokens: Int, countTokens: (String) async throws -> Int
    ) async throws -> String {
        let items = try candidates(
            store: store, run: run, question: question, priorTurns: priorTurns, componentContext: componentContext)
        var budget = max(budgetTokens, 0)
        var context = pack(items, budgetTokens: budget)
        for _ in 0..<3 {
            let actual = try await countTokens(context)
            guard actual > budgetTokens else { break }
            budget = max(0, budget - (actual - budgetTokens) - 32)
            context = pack(items, budgetTokens: budget)
        }
        return context
    }

    // MARK: - Words

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "what", "how", "does", "where", "which", "when", "why", "this", "that",
        "from", "into", "are", "was", "were", "has", "have", "can", "its", "use", "used", "using", "who",
        "about", "there", "their", "they", "them", "then", "than", "will", "would", "should", "could",
        "you", "your", "not", "but", "all", "any", "each", "between", "work", "works", "happen", "happens",
    ]

    /// Lowercased words of 3+ characters, identifiers also split into their parts.
    static func terms(_ text: String) -> Set<String> {
        var out: Set<String> = []
        for raw in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
            let word = String(raw)
            for part in [word] + identifierParts(word) {
                let lower = part.lowercased()
                if lower.count >= 3, !stopwords.contains(lower) { out.insert(lower) }
            }
        }
        return out
    }

    /// Words that look like code (`add_route`, `Router`, `HTTPException`): symbol-search keys.
    static func codeWords(_ question: String) -> [String] {
        var seen: Set<String> = []
        return question.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .map(String.init)
            .filter { word in
                word.count >= 3 && !stopwords.contains(word.lowercased())
                    && (word.contains("_") || word.dropFirst().contains(where: \.isUppercase) || word.first?.isUppercase == true)
            }
            .filter { seen.insert($0).inserted }
            .prefix(4)
            .map { $0 }
    }

    private static func identifierParts(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in word {
            if ch == "_" {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else if ch.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.count > 1 ? parts : []
    }

    static func overlap(_ terms: Set<String>, _ text: String) -> Double {
        guard !terms.isEmpty else { return 0 }
        return Double(terms.intersection(self.terms(text)).count)
    }

    static func estimate(_ text: String) -> Int {
        Int((Double(text.count) / charsPerToken).rounded(.up))
    }

    static func truncated(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}
