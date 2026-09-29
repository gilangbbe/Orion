import ArgumentParser
import Foundation
import OrionAgent
import OrionCodeIntel

/// `orion-agent teach` (Docs/17_phase7_teaching_mode.md §10, M5) — the product surface for
/// Teaching Mode: list concepts + mastery, get the next question to work on, submit an answer for
/// a decomposed-rubric grade, and inspect the developer's knowledge state. Replaces the M1–M4
/// standalone debug commands (`teach-generate` / `teach-answer`); concept *extraction* itself
/// stays `orion-index teach-concepts --extract` (pure, deterministic, no agent), though `teach
/// concepts`/`teach next` will bootstrap an empty concept table on first use for convenience.
struct Teach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teach",
        abstract: "Teaching Mode: concepts, the next question, grading an answer, knowledge state.",
        subcommands: [TeachConcepts.self, TeachNext.self, TeachAnswer.self, TeachState.self, TeachBench.self]
    )
}

// MARK: shared

private func resolvePaths(path: String, out: String?) -> (repoURL: URL, outURL: URL) {
    let repoURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    let outURL = URL(
        fileURLWithPath: ((out ?? repoURL.appendingPathComponent(".orion").path) as NSString)
            .expandingTildeInPath
    ).standardizedFileURL
    return (repoURL, outURL)
}

private func openStore(_ outURL: URL) throws -> Store {
    let dbPath = outURL.appendingPathComponent("orion.db").path
    guard FileManager.default.fileExists(atPath: dbPath) else {
        FileHandle.standardError.write(Data("no database at \(dbPath) — run `orion-index analyze` first\n".utf8))
        throw ExitCode(3)
    }
    return Store(try OrionDatabase(path: dbPath))
}

private func requireRun(_ store: Store, commit: String?) throws -> AnalysisRunRecord {
    guard let run = try store.latestRun(commitHash: commit) else {
        FileHandle.standardError.write(Data("no analyzed run — run `orion-index analyze` first\n".utf8))
        throw ExitCode(3)
    }
    return run
}

/// Bootstrap the concept table on first use so `teach next` / `teach concepts` "just work" after
/// a semantic investigation, without a separate `orion-index teach-concepts --extract` step.
@discardableResult
private func ensureConcepts(
    _ store: Store, run: AnalysisRunRecord, force: Bool
) throws -> [TeachingConceptRecord] {
    var concepts = try store.teachingConcepts(repositoryId: run.repositoryId)
    if concepts.isEmpty || force {
        let r = try ConceptExtractor.extract(
            store: store, commitHash: run.commitHash, now: ISO8601DateFormatter().string(from: Date()))
        if r.inserted.count > 0 || force {
            FileHandle.standardError.write(Data(
                "extracted \(r.inserted.count) concept(s), \(r.deduped) deduped, \(r.cappedOut) over cap\n".utf8))
        }
        concepts = try store.teachingConcepts(repositoryId: run.repositoryId)
    }
    if concepts.isEmpty {
        FileHandle.standardError.write(Data(
            "no teaching concepts — this repository has no semantic investigation to derive them from\n".utf8))
        throw ExitCode(3)
    }
    return concepts
}

private func resolveConcept(
    _ concepts: [TeachingConceptRecord], query: String
) throws -> TeachingConceptRecord {
    if let byId = concepts.first(where: { $0.id == query }) { return byId }
    if let byLabel = concepts.first(where: { $0.subjectLabel.caseInsensitiveCompare(query) == .orderedSame }) {
        return byLabel
    }
    throw ValidationError("no concept matching \"\(query)\" (by id or exact label)")
}

// MARK: teach concepts

struct TeachConcepts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "concepts",
        abstract: "List this repository's teaching concepts with the developer's mastery of each."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String
    @Option(help: "Directory containing orion.db (default: <path>/.orion).")
    var out: String?
    @Option(help: "Use this commit's analyzed run instead of the latest.")
    var commit: String?
    @Option(help: "Developer id for mastery lookup (default: local).")
    var developer: String = "local"
    @Flag(help: "Re-run concept extraction before listing.")
    var extract: Bool = false
    @Flag(help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL)
        let run = try requireRun(store, commit: commit)
        let concepts = try ensureConcepts(store, run: run, force: extract)

        struct Row { let c: TeachingConceptRecord; let p: Double; let band: String; let n: Int; let misc: Int }
        let rows = try concepts.map { c -> Row in
            let ks = try store.knowledgeState(developerId: developer, conceptId: c.id)
            let misc = try ks.map { try store.teachingMisconceptions(knowledgeStateId: $0.id, openOnly: true).count } ?? 0
            return Row(
                c: c, p: ks?.pMastered ?? 0.15, band: ks?.confidenceBand ?? "new",
                n: ks?.attemptsCount ?? 0, misc: misc)
        }

        if json {
            let objs = rows.map { r -> [String: Any] in
                [
                    "id": r.c.id, "kind": r.c.kind, "subject_label": r.c.subjectLabel,
                    "difficulty_band": r.c.difficultyBand, "centrality": r.c.centrality,
                    "p_mastered": r.p, "confidence_band": r.band, "attempts": r.n,
                    "open_misconceptions": r.misc,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: objs, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for r in rows {
            let m = r.misc > 0 ? "  ⚠\(r.misc)" : ""
            print(String(
                format: "  [%@ · band %d · c=%.2f]  %@  —  %@ (p=%.2f, n=%d)%@",
                r.c.kind, r.c.difficultyBand, r.c.centrality, r.c.subjectLabel, r.band, r.p, r.n, m))
        }
    }
}

// MARK: teach next

struct TeachNext: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next",
        abstract: "Pick the next concept to work on and print a question (reusing a verified one if it exists)."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String
    @Option(help: "Directory containing orion.db + export/ (default: <path>/.orion).")
    var out: String?
    @Option(help: "Use this commit's analyzed run instead of the latest.")
    var commit: String?
    @Option(help: "Developer id (default: local).")
    var developer: String = "local"
    @Option(help: "Force a specific concept (by id or exact label) instead of the planner's pick.")
    var concept: String?
    @Option(help: "Force difficulty band 1–3 (default: the concept's own seed band).")
    var band: Int?
    @Option(help: "Comma-separated concept ids recently worked on (demoted by the planner).")
    var recent: String?
    @Option(help: "Drafter for a fresh question: local | claude | auto (default: auto — band ≤2 local, band 3 claude).")
    var source: String = "auto"
    @Option(name: .customLong("max-budget-usd"), help: "Cost ceiling for a Claude drafting call.")
    var maxBudgetUsd: Double = 0.50
    @Option(help: "Wall-clock timeout (s) for a Claude drafting call.")
    var timeout: Double = 400
    @Flag(help: "Always generate a fresh question even if a verified one exists.")
    var fresh: Bool = false
    @OptionGroup var backend: LocalBackendOption
    @Flag(help: "Emit JSON.")
    var json: Bool = false

    func validate() throws {
        if let band, !(1...3).contains(band) { throw ValidationError("--band must be 1, 2, or 3") }
        if !["local", "claude", "auto"].contains(source) {
            throw ValidationError("--source must be local, claude, or auto")
        }
    }

    func run() async throws {
        let (repoURL, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL)
        let run = try requireRun(store, commit: commit)
        let concepts = try ensureConcepts(store, run: run, force: false)

        let target: TeachingConceptRecord
        if let concept {
            target = try resolveConcept(concepts, query: concept)
        } else {
            let recentIds = (recent ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let picked = try TeachingPlanner(store: store).next(
                repositoryId: run.repositoryId, developerId: developer, recentConceptIds: recentIds)
            else {
                FileHandle.standardError.write(Data("no concept to pick\n".utf8))
                throw ExitCode(3)
            }
            target = picked
        }
        let targetBand = band ?? target.difficultyBand

        // Reuse a verified question: newest one, matching the target band if --band was explicit.
        let existing = try store.teachingQuestions(conceptId: target.id, verifiedOnly: true)
        let reusable = fresh ? nil : (band != nil
            ? existing.last { $0.difficultyBand == targetBand }
            : existing.last)

        let question: TeachingQuestionRecord
        let generatedFresh: Bool
        if let reusable {
            question = reusable
            generatedFresh = false
        } else {
            let useClaude = source == "claude" || (source == "auto" && targetBand >= 3)
            let drafter: any TeachingQuestionDrafting
            if useClaude {
                drafter = ClaudeTeachingDrafter(
                    repoRoot: repoURL, exportDir: outURL.appendingPathComponent("export"),
                    maxBudgetUsd: maxBudgetUsd, timeoutSeconds: timeout)
            } else {
                let agent = try await LocalModelLoader.shared.model(for: try backend.resolve(), role: .drafting)
                drafter = LocalTeachingDrafter { p in
                    try await agent.respond(to: p, instructions: LocalTeachingDrafter.systemInstruction)
                }
            }
            let result = try await TeachingQuestionGenerator(store: store, run: run, drafter: drafter)
                .generate(concept: target, band: targetBand)
            switch result {
            case .generated(let qid, _, let dropped, let attempts):
                if dropped > 0 || attempts > 1 {
                    FileHandle.standardError.write(Data(
                        "generated in \(attempts) attempt(s), \(dropped) criteria dropped\n".utf8))
                }
                question = try store.teachingQuestion(id: qid)!
            case .rejected(let reasons, _):
                let msg = "could not generate a valid question:\n"
                    + reasons.map { "  - \($0)" }.joined(separator: "\n") + "\n"
                FileHandle.standardError.write(Data(msg.utf8))
                throw ExitCode(1)
            case .draftUnusable(let detail, _):
                FileHandle.standardError.write(Data("no usable draft: \(detail)\n".utf8))
                throw ExitCode(1)
            }
            generatedFresh = true
        }

        if json {
            let obj: [String: Any] = [
                "concept_id": target.id, "concept": target.subjectLabel, "kind": target.kind,
                "question_id": question.id, "band": question.difficultyBand,
                "reused": !generatedFresh, "explain": question.explain, "question": question.prompt,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print("Concept: [\(target.kind)] \(target.subjectLabel)")
        print("Question \(question.id)  (band \(question.difficultyBand)\(generatedFresh ? ", new" : ", reused"))")
        print("\nEXPLAIN\n\(question.explain)")
        print("\nQUESTION\n\(question.prompt)")
        print("\nAnswer with:  orion-agent teach answer \(path) \(question.id) \"<your answer>\"")
    }
}

// MARK: teach answer

struct TeachAnswer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "answer",
        abstract: "Grade an answer to a teaching question (per-criterion checklist, derived score, mastery update)."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String
    @Argument(help: "The question id (from `teach next`).")
    var questionId: String
    @Argument(help: "The developer's answer.")
    var answer: String
    @Option(help: "Directory containing orion.db (default: <path>/.orion).")
    var out: String?
    @Option(help: "Use this commit's analyzed run instead of the latest.")
    var commit: String?
    @Option(help: "Developer id (default: local).")
    var developer: String = "local"
    @Option(help: "k for per-criterion self-consistency voting (default 3).")
    var k: Int = 3
    @Flag(help: "Also run the pairwise reference-sanity tripwire (§7.4).")
    var pairwise: Bool = false
    @OptionGroup var backend: LocalBackendOption
    @OptionGroup var judgeOutputOption: JudgeOutputOption
    @Flag(help: "Print the k-vote detail and pairwise result.")
    var explain: Bool = false
    @Flag(help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL)
        let run = try requireRun(store, commit: commit)
        guard let question = try store.teachingQuestion(id: questionId) else {
            FileHandle.standardError.write(Data("no question with id \(questionId)\n".utf8))
            throw ExitCode(3)
        }

        let localBackend = try backend.resolve()
        let judgeOutput = try judgeOutputOption.resolve()
        let agent = try await LocalModelLoader.shared.model(for: localBackend, role: .judging)
        let judge = try LocalGrading.judge(agent: agent, output: judgeOutput)
        let comparerAgent = pairwise
            ? try await LocalModelLoader.shared.model(for: localBackend, role: .comparing) : nil
        let comparer = try comparerAgent.map { try LocalGrading.comparer(agent: $0, output: judgeOutput) }

        let result: RubricGrader.Result
        do {
            result = try await RubricGrader(store: store, run: run, judge: judge, comparer: comparer, k: k)
                .grade(questionId: questionId, answer: answer, developerId: developer)
        } catch {
            FileHandle.standardError.write(Data("grade failed: \(error)\n".utf8))
            throw ExitCode(1)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            print(String(decoding: try encoder.encode(JSONOut(result, transfer: question.transferProblem)), as: UTF8.self))
            return
        }

        for c in result.perCriterion {
            let mark = c.kind == .anti ? (c.met ? "⚠" : "·") : (c.met ? "✓" : "✗")
            let conf = c.confidence == .low ? " (needs review)" : ""
            print("  \(mark) [\(c.kind.rawValue)] \(c.text)\(conf)")
            if explain, !c.note.isEmpty { print("      \(c.note)") }
        }
        print("")
        print(String(format: "score %.2f  →  %@   (%d/%d required, %d bonus, %d anti)",
                     result.score, result.verdict.rawValue, result.requiredMet, result.requiredTotal,
                     result.bonusMet, result.antiTripped))
        if result.disputed { print("⚑ score disputed by the pairwise same-idea check") }
        if explain, let same = result.pairwiseSameIdea { print("pairwise same-idea: \(same)") }
        for m in result.misconceptionsDetected { print("misconception detected: \(m)") }
        for m in result.misconceptionsCleared { print("misconception cleared: \(m)") }
        if let ks = result.knowledgeState {
            print(String(format: "mastery: p %.2f → %.2f   band %@ → %@   (attempt %d)",
                         ks.previousPMastered, ks.newPMastered, ks.previousBand, ks.newBand, ks.attemptsCount))
        }
        print("\n\(result.correction)")
        if let t = question.transferProblem, !t.isEmpty {
            print("\nTRANSFER PROBLEM\n\(t)")
        }
    }

    private struct JSONOut: Encodable {
        struct KS: Encodable {
            var previousPMastered, newPMastered: Double
            var previousBand, newBand: String
            var attemptsCount: Int
        }
        var attemptId: String
        var score: Double
        var verdict: String
        var requiredMet, requiredTotal, bonusMet, antiTripped: Int
        var needsReview: [String]
        var disputed: Bool
        var pairwiseSameIdea: Bool?
        var misconceptionsDetected, misconceptionsCleared: [String]
        var knowledgeState: KS?
        var correction: String
        var transferProblem: String?
        init(_ r: RubricGrader.Result, transfer: String?) {
            attemptId = r.attemptId
            score = r.score
            verdict = r.verdict.rawValue
            requiredMet = r.requiredMet
            requiredTotal = r.requiredTotal
            bonusMet = r.bonusMet
            antiTripped = r.antiTripped
            needsReview = r.needsReview
            disputed = r.disputed
            pairwiseSameIdea = r.pairwiseSameIdea
            misconceptionsDetected = r.misconceptionsDetected
            misconceptionsCleared = r.misconceptionsCleared
            knowledgeState = r.knowledgeState.map {
                KS(previousPMastered: $0.previousPMastered, newPMastered: $0.newPMastered,
                   previousBand: $0.previousBand, newBand: $0.newBand, attemptsCount: $0.attemptsCount)
            }
            correction = r.correction
            transferProblem = transfer
        }
    }
}

// MARK: teach state

struct TeachState: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Show the developer's knowledge state: mastery per concept and open misconceptions."
    )

    @Argument(help: "Path to the repository checkout.")
    var path: String
    @Option(help: "Directory containing orion.db (default: <path>/.orion).")
    var out: String?
    @Option(help: "Developer id (default: local).")
    var developer: String = "local"
    @Flag(help: "Emit JSON.")
    var json: Bool = false

    func run() async throws {
        let (_, outURL) = resolvePaths(path: path, out: out)
        let store = try openStore(outURL)

        let states = try store.knowledgeStates(developerId: developer)
        struct Row {
            let label: String; let kind: String; let p: Double; let band: String
            let n: Int; let lastVerdict: String?; let open: [String]
        }
        let rows = try states.map { ks -> Row in
            let concept = try store.teachingConcept(id: ks.conceptId)
            let open = try store.teachingMisconceptions(knowledgeStateId: ks.id, openOnly: true).map(\.statement)
            return Row(
                label: concept?.subjectLabel ?? ks.conceptId, kind: concept?.kind ?? "?",
                p: ks.pMastered, band: ks.confidenceBand, n: ks.attemptsCount,
                lastVerdict: ks.lastVerdict, open: open)
        }

        if json {
            let objs = rows.map { r -> [String: Any] in
                var o: [String: Any] = [
                    "concept": r.label, "kind": r.kind, "p_mastered": r.p,
                    "confidence_band": r.band, "attempts": r.n, "open_misconceptions": r.open,
                ]
                if let v = r.lastVerdict { o["last_verdict"] = v }
                return o
            }
            let data = try JSONSerialization.data(withJSONObject: objs, options: [.sortedKeys, .prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            return
        }

        guard !rows.isEmpty else {
            print("No knowledge state yet — answer a question with `orion-agent teach answer`.")
            return
        }
        let mastered = rows.filter { $0.band == "solid" }.count
        let misc = rows.reduce(0) { $0 + $1.open.count }
        print("\(rows.count) concept(s) engaged · \(mastered) solid · \(misc) open misconception(s)\n")
        for r in rows {
            print(String(format: "  %@ · %@  —  %@ (p=%.2f, n=%d%@)",
                         r.kind, r.label, r.band, r.p, r.n,
                         r.lastVerdict.map { ", last \($0)" } ?? ""))
            for m in r.open { print("      ⚠ \(m)") }
        }
    }
}
