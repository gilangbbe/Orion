/// Orion Phase 1 — deterministic code intelligence.
///
/// Pure structural extraction: repository → AST → symbols → references → dependencies →
/// call graph → Code Graph. No LLM, no network model calls. See
/// `Docs/10_phase1_deterministic_code_intelligence.md`.
public enum OrionCodeIntel {
    /// Semantic version of the indexer. Stamped onto `analysis_runs.orion_version` and the
    /// JSON export so downstream artifacts are traceable to a build.
    public static let version = "0.1.0"
}
