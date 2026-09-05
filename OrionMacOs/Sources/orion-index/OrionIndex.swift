import ArgumentParser
import OrionCodeIntel

@main
struct OrionIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orion-index",
        abstract: "Deterministic code-intelligence indexer for Orion (Phase 1).",
        discussion: """
        Builds a structural Code Graph (files → symbols → references → dependencies →
        call graph) for a Python repository and writes it to SQLite plus a JSON/JSONL
        export. No LLM is involved. See Docs/10_phase1_deterministic_code_intelligence.md.
        """,
        version: OrionCodeIntel.version,
        subcommands: [Analyze.self, Stats.self, Export.self, Query.self, IngestSemantic.self]
    )
}
