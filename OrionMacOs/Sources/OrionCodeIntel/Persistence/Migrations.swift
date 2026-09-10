import Foundation
import GRDB

/// The Code Graph schema. One migration per schema change, never edited after commit.
/// `v1_phase1_schema` is the deterministic Code Graph (Phase 1, frozen). `v2_phase2_schema`
/// adds the semantic tables (`components`, `claims`, `evidence`, …) Phase 2 populates via
/// `SemanticImporter` — additive only, so Phase 1's schema/snapshot are untouched.
/// `v3_phase3_schema` adds the MLX Agent's own tables (`routing_decisions`, and later
/// `agent_tool_calls` once Phase 3's M2 tool loop lands) — see
/// `Docs/12_phase3_mlx_agent.md` "SQLite schema". These are agent-loop artifacts, not code-graph
/// facts, but they live in this same migrator/Store because Phase 2 already established the
/// precedent of one shared database rather than a second competing persistence stack.
/// `v4_phase5_schema` adds `ask_sessions`/`ask_session_turns` — persisted, resumable multi-turn
/// conversations layered over `investigations` (Docs/15's own naming callout: a session is a
/// thin ordered pointer over existing investigation rows, not a second transcript store). Unlike
/// `v3`, Phase 3/4/4.5 already shipped, so this is a genuinely new migration rather than an
/// amendment to an unreleased one — the "amend, don't version" precedent only ever applied while
/// a phase's own schema was still pre-release.
/// `v5_phase6_schema` adds `model_revision_entries` plus one additive column
/// (`model_revisions.revision_number`) — the real structured diff Docs/16's `RevisionDiffer`
/// computes between investigations, replacing Phase 2/3's coarse one-row-per-ingestion log. Same
/// "genuinely new migration, not an amendment" reasoning as `v4`: Phase 2's `model_revisions`
/// table already shipped.
public enum OrionMigrations {

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        registerV5(&migrator)
        return migrator
    }

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_phase1_schema") { db in
            try db.execute(sql: Self.v1SQL)
        }
    }

    private static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_phase2_schema") { db in
            try db.execute(sql: Self.v2SQL)
        }
    }

    private static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_phase3_schema") { db in
            try db.execute(sql: Self.v3SQL)
        }
    }

    private static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4_phase5_schema") { db in
            try db.execute(sql: Self.v4SQL)
        }
    }

    private static func registerV5(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_phase6_schema") { db in
            try db.execute(sql: Self.v5SQL)
        }
    }

    private static let v1SQL = """
    CREATE TABLE repositories (
        id              TEXT PRIMARY KEY,
        source_url      TEXT,
        local_path      TEXT NOT NULL,
        commit_hash     TEXT NOT NULL,
        languages       TEXT NOT NULL DEFAULT '[]',
        analysis_status TEXT NOT NULL DEFAULT 'pending',
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        UNIQUE (local_path, commit_hash)
    );

    CREATE TABLE analysis_runs (
        id                 TEXT PRIMARY KEY,
        repository_id      TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash        TEXT NOT NULL,
        status             TEXT NOT NULL,
        started_at         TEXT NOT NULL,
        finished_at        TEXT,
        orion_version      TEXT NOT NULL,
        resolver           TEXT NOT NULL DEFAULT 'none',
        grammar_versions   TEXT NOT NULL DEFAULT '{}',
        tool_versions      TEXT NOT NULL DEFAULT '{}',
        stage_timings      TEXT NOT NULL DEFAULT '{}',
        file_count         INTEGER NOT NULL DEFAULT 0,
        symbol_count       INTEGER NOT NULL DEFAULT 0,
        relationship_count INTEGER NOT NULL DEFAULT 0,
        diagnostic_count   INTEGER NOT NULL DEFAULT 0,
        error              TEXT
    );
    CREATE INDEX idx_runs_repo ON analysis_runs(repository_id, commit_hash, status);

    CREATE TABLE files (
        id              TEXT PRIMARY KEY,
        repository_id   TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash     TEXT NOT NULL,
        run_id          TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        path            TEXT NOT NULL,
        language        TEXT,
        module_path     TEXT,
        sha256          TEXT NOT NULL,
        byte_size       INTEGER NOT NULL,
        line_count      INTEGER NOT NULL,
        is_test         INTEGER NOT NULL DEFAULT 0,
        is_package_init INTEGER NOT NULL DEFAULT 0,
        parse_ok        INTEGER NOT NULL DEFAULT 1,
        UNIQUE (run_id, path)
    );
    CREATE INDEX idx_files_scope  ON files(repository_id, commit_hash);
    CREATE INDEX idx_files_module ON files(run_id, module_path);

    CREATE TABLE external_dependencies (
        id            TEXT PRIMARY KEY,
        repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash   TEXT NOT NULL,
        run_id        TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        name          TEXT NOT NULL,
        distribution  TEXT,
        source        TEXT NOT NULL,
        version_spec  TEXT,
        is_stdlib     INTEGER NOT NULL DEFAULT 0,
        import_count  INTEGER NOT NULL DEFAULT 0,
        UNIQUE (run_id, name)
    );

    CREATE TABLE symbols (
        id               TEXT PRIMARY KEY,
        repository_id    TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash      TEXT NOT NULL,
        run_id           TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        file_id          TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        component_id     TEXT,
        parent_symbol_id TEXT REFERENCES symbols(id) ON DELETE CASCADE,
        name             TEXT NOT NULL,
        qualified_name   TEXT NOT NULL,
        anchor           TEXT NOT NULL,
        kind             TEXT NOT NULL,
        start_line       INTEGER NOT NULL,
        start_col        INTEGER NOT NULL,
        end_line         INTEGER NOT NULL,
        end_col          INTEGER NOT NULL,
        start_byte       INTEGER NOT NULL,
        end_byte         INTEGER NOT NULL,
        signature        TEXT,
        docstring        TEXT,
        decorators       TEXT NOT NULL DEFAULT '[]',
        visibility       TEXT NOT NULL DEFAULT 'public',
        is_exported      INTEGER NOT NULL DEFAULT 1,
        redirects_to     TEXT,
        epistemic_type   TEXT NOT NULL DEFAULT 'FACT',
        UNIQUE (run_id, anchor)
    );
    CREATE INDEX idx_symbols_scope ON symbols(repository_id, commit_hash);
    CREATE INDEX idx_symbols_qname ON symbols(run_id, qualified_name);
    CREATE INDEX idx_symbols_file  ON symbols(file_id);

    CREATE TABLE relationships (
        id                    TEXT PRIMARY KEY,
        repository_id         TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash           TEXT NOT NULL,
        run_id                TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        relationship_type     TEXT NOT NULL,
        source_symbol_id      TEXT REFERENCES symbols(id) ON DELETE CASCADE,
        target_symbol_id      TEXT REFERENCES symbols(id) ON DELETE CASCADE,
        external_dependency_id TEXT REFERENCES external_dependencies(id) ON DELETE CASCADE,
        source_ref            TEXT,
        target_ref            TEXT,
        provenance            TEXT NOT NULL,
        confidence            REAL NOT NULL,
        confidence_tier       TEXT NOT NULL,
        resolved              INTEGER NOT NULL DEFAULT 0,
        epistemic_type        TEXT NOT NULL DEFAULT 'FACT',
        site_file_id          TEXT REFERENCES files(id) ON DELETE CASCADE,
        site_start_line       INTEGER,
        site_start_col        INTEGER,
        site_end_line         INTEGER,
        site_end_col          INTEGER,
        UNIQUE (run_id, relationship_type, source_symbol_id, target_symbol_id,
                source_ref, target_ref, site_start_line, site_start_col)
    );
    CREATE INDEX idx_rel_scope  ON relationships(repository_id, commit_hash);
    CREATE INDEX idx_rel_source ON relationships(run_id, source_symbol_id, relationship_type);
    CREATE INDEX idx_rel_target ON relationships(run_id, target_symbol_id, relationship_type);

    CREATE TABLE diagnostics (
        id            TEXT PRIMARY KEY,
        repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash   TEXT NOT NULL,
        run_id        TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        file_id       TEXT REFERENCES files(id) ON DELETE CASCADE,
        stage         TEXT NOT NULL,
        severity      TEXT NOT NULL,
        code          TEXT NOT NULL,
        message       TEXT NOT NULL,
        start_line    INTEGER,
        start_col     INTEGER,
        end_line      INTEGER,
        end_col       INTEGER
    );
    CREATE INDEX idx_diag_scope ON diagnostics(run_id, stage, severity);
    """

    /// Phase 2 semantic tables. Additive only — no Phase 1 table is altered, so Phase 1's
    /// golden snapshot and tests are unaffected. See
    /// `Docs/11_phase2_semantic_analysis.md` "SQLite v2 schema". `knowledge_states` stays
    /// reserved and unbuilt (Phase 7 — Teaching).
    private static let v2SQL = """
    CREATE TABLE investigations (
        id                 TEXT PRIMARY KEY,
        repository_id      TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash        TEXT NOT NULL,
        run_id             TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        question           TEXT NOT NULL DEFAULT 'phase2_semantic_grouping',
        complexity         TEXT NOT NULL DEFAULT 'high',
        schema_version     TEXT,
        model_used         TEXT,
        tools_used         TEXT NOT NULL DEFAULT '[]',
        session_id         TEXT,
        num_turns          INTEGER,
        total_cost_usd     REAL,
        duration_ms        REAL,
        outcome            TEXT NOT NULL DEFAULT 'unverified',
        created_at         TEXT NOT NULL
    );
    CREATE INDEX idx_investigations_scope ON investigations(repository_id, commit_hash, run_id);

    CREATE TABLE components (
        id                  TEXT PRIMARY KEY,
        repository_id       TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash         TEXT NOT NULL,
        run_id              TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        investigation_id    TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
        name                TEXT NOT NULL,
        description         TEXT,
        architectural_role  TEXT,
        confidence          REAL NOT NULL,
        confidence_tier     TEXT NOT NULL,
        status              TEXT NOT NULL DEFAULT 'active',
        epistemic_type      TEXT NOT NULL DEFAULT 'INTERPRETATION',
        provenance          TEXT NOT NULL DEFAULT 'claude_code',
        -- Scoped to investigation, not run: M6 (Docs/11) runs multiple independent
        -- investigations against the same analysis run to measure repeatability, and
        -- Claude reusing a component name across separate investigations ("Middleware
        -- Stack" in both) is expected, not a real duplicate -- a run_id-scoped UNIQUE
        -- constraint blocked exactly that with a raw SQLite error. Within-one-investigation
        -- duplicate names are still caught by SemanticImporter's own consistency check
        -- (step 3, de-dup keeps the first occurrence) before a row is ever inserted here.
        UNIQUE (investigation_id, name)
    );
    CREATE INDEX idx_components_scope ON components(repository_id, commit_hash, run_id);
    CREATE INDEX idx_components_investigation ON components(investigation_id);

    CREATE TABLE component_members (
        id           TEXT PRIMARY KEY,
        component_id TEXT NOT NULL REFERENCES components(id) ON DELETE CASCADE,
        symbol_id    TEXT NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
        confidence   REAL NOT NULL,
        role         TEXT NOT NULL DEFAULT 'core',
        UNIQUE (component_id, symbol_id)
    );
    CREATE INDEX idx_component_members_symbol ON component_members(symbol_id);

    CREATE TABLE component_relationships (
        id                   TEXT PRIMARY KEY,
        repository_id        TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash          TEXT NOT NULL,
        run_id               TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        investigation_id     TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
        source_component_id  TEXT NOT NULL REFERENCES components(id) ON DELETE CASCADE,
        target_component_id  TEXT NOT NULL REFERENCES components(id) ON DELETE CASCADE,
        relationship_type    TEXT NOT NULL,
        confidence           REAL NOT NULL,
        confidence_tier      TEXT NOT NULL,
        provenance           TEXT NOT NULL DEFAULT 'claude_code',
        UNIQUE (run_id, source_component_id, target_component_id, relationship_type)
    );
    CREATE INDEX idx_component_rel_scope ON component_relationships(repository_id, commit_hash, run_id);

    CREATE TABLE claims (
        id                TEXT PRIMARY KEY,
        repository_id     TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash       TEXT NOT NULL,
        run_id            TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
        investigation_id  TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
        -- subject_ref/predicate/object_ref: nullable. Claude's actual candidate JSON
        -- (Docs/11 SEMANTIC_SCHEMA) gives a claim as statement+evidence, not a structured
        -- triple; SemanticImporter sets subject_ref to the claim's first resolved evidence
        -- anchor when one exists (an uncertainties[]-derived claim has none).
        subject_ref       TEXT,
        predicate         TEXT,
        object_ref        TEXT,
        statement         TEXT NOT NULL,
        claim_type        TEXT NOT NULL,
        confidence        REAL NOT NULL,
        status            TEXT NOT NULL DEFAULT 'active',
        created_by        TEXT NOT NULL DEFAULT 'claude_code'
    );
    CREATE INDEX idx_claims_scope ON claims(repository_id, commit_hash, run_id);
    CREATE INDEX idx_claims_investigation ON claims(investigation_id);

    CREATE TABLE evidence (
        id            TEXT PRIMARY KEY,
        claim_id      TEXT NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
        file_id       TEXT REFERENCES files(id) ON DELETE CASCADE,
        symbol_id     TEXT REFERENCES symbols(id) ON DELETE CASCADE,
        anchor        TEXT NOT NULL,
        start_line    INTEGER,
        end_line      INTEGER,
        evidence_type TEXT NOT NULL DEFAULT 'source'
    );
    CREATE INDEX idx_evidence_claim ON evidence(claim_id);

    CREATE TABLE model_revisions (
        id                          TEXT PRIMARY KEY,
        repository_id               TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        previous_revision           TEXT REFERENCES model_revisions(id) ON DELETE SET NULL,
        change_summary              TEXT NOT NULL,
        triggering_investigation_id TEXT REFERENCES investigations(id) ON DELETE CASCADE,
        created_at                  TEXT NOT NULL
    );
    CREATE INDEX idx_model_revisions_repo ON model_revisions(repository_id, created_at);
    """

    /// Phase 3 agent tables. Additive only — no Phase 1/2 table is altered. See
    /// `Docs/12_phase3_mlx_agent.md` "SQLite schema". `routing_decisions` (M1) and
    /// `agent_tool_calls` (M2) both amend this same pre-release migration directly rather than
    /// adding a `v4`/`v5` — same precedent Phase 2's M2 set for amending an unshipped schema.
    private static let v3SQL = """
    CREATE TABLE routing_decisions (
        id               TEXT PRIMARY KEY,
        investigation_id TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
        depth_level      INTEGER NOT NULL,
        method           TEXT NOT NULL,
        confidence       TEXT NOT NULL,
        rationale        TEXT NOT NULL,
        created_at       TEXT NOT NULL
    );
    CREATE INDEX idx_routing_decisions_investigation ON routing_decisions(investigation_id);

    CREATE TABLE agent_tool_calls (
        id               TEXT PRIMARY KEY,
        investigation_id TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
        turn_index       INTEGER NOT NULL,
        tool_name        TEXT NOT NULL,
        arguments        TEXT NOT NULL DEFAULT '{}',
        result_summary   TEXT NOT NULL,
        latency_ms       REAL,
        created_at       TEXT NOT NULL
    );
    CREATE INDEX idx_agent_tool_calls_investigation ON agent_tool_calls(investigation_id, turn_index);
    """

    /// Phase 5 conversational-session tables, plus one additive column on the existing Phase 2
    /// `investigations` table. See `Docs/15_phase5_adaptive_exploration.md` §4.2 "Schema". A
    /// session's `component_id` references one specific past investigation's `components` row
    /// (components are scoped to an investigation, not a stable cross-investigation identity —
    /// Docs/11); NULL means a repository-wide session. `claude_session_id` denormalizes the most
    /// recent depth-3 turn's `investigations.session_id` (Claude CLI's own, unrelated identifier
    /// — see Docs/15 §4.2's naming callout) so `--resume` doesn't need a join to find it.
    ///
    /// `investigations.answer_text` — real M3 finding, not part of the original M0 schema draft:
    /// building prior-turn context (Docs/15 §4.3) needs each past turn's actual answer text, and
    /// nothing persisted it anywhere — `SemanticIngestOutcome.answer`/`AgentSessionResult
    /// .answerText` were both transient, computed at ask-time and handed back to the caller, never
    /// written to a column. `ALTER TABLE` on an already-shipped Phase 2 table is safe here
    /// specifically because it's a new, nullable column added by a *new* migration (`v4`, not yet
    /// released) — `v2_phase2_schema`'s own migration script is untouched, this is normal schema
    /// evolution, not rewriting an already-applied migration's history.
    private static let v4SQL = """
    ALTER TABLE investigations ADD COLUMN answer_text TEXT;

    CREATE TABLE ask_sessions (
        id                TEXT PRIMARY KEY,
        repository_id     TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
        commit_hash       TEXT NOT NULL,
        scope_type        TEXT NOT NULL,
        component_id      TEXT REFERENCES components(id) ON DELETE CASCADE,
        title             TEXT NOT NULL,
        claude_session_id TEXT,
        turn_count        INTEGER NOT NULL DEFAULT 0,
        created_at        TEXT NOT NULL,
        last_active_at    TEXT NOT NULL
    );
    CREATE INDEX idx_ask_sessions_repo ON ask_sessions(repository_id, commit_hash, last_active_at);
    CREATE INDEX idx_ask_sessions_component ON ask_sessions(component_id);

    CREATE TABLE ask_session_turns (
        id               TEXT PRIMARY KEY,
        session_id       TEXT NOT NULL REFERENCES ask_sessions(id) ON DELETE CASCADE,
        turn_index       INTEGER NOT NULL,
        investigation_id TEXT NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
        created_at       TEXT NOT NULL,
        UNIQUE (session_id, turn_index)
    );
    CREATE INDEX idx_ask_session_turns_session ON ask_session_turns(session_id, turn_index);
    """

    /// Phase 6 continuous-model-update tables, plus one additive column on the existing Phase 2
    /// `model_revisions` table. See `Docs/16_phase6_continuous_model_updates.md` §2 "Schema".
    /// `revision_number` is monotonic per `repository_id` — each `repositories` row is already
    /// scoped to one commit via its own `UNIQUE(local_path, commit_hash)` (Phase 1), so no
    /// separate `commit_hash` column is needed on either table here, unlike this phase's own doc
    /// draft, which had sketched `(repository_id, commit_hash)` before this was implemented.
    /// `model_revision_entries.related_claim_id` is `ON DELETE SET NULL` (not `CASCADE`) — an
    /// "addressed" uncertainty entry (§5) stays meaningful even once the claim it hedged a link to
    /// is later deleted.
    private static let v5SQL = """
    ALTER TABLE model_revisions ADD COLUMN revision_number INTEGER NOT NULL DEFAULT 1;

    CREATE TABLE model_revision_entries (
        id                  TEXT PRIMARY KEY,
        model_revision_id   TEXT NOT NULL REFERENCES model_revisions(id) ON DELETE CASCADE,
        entity_type         TEXT NOT NULL,
        change_type         TEXT NOT NULL,
        subject_label       TEXT NOT NULL,
        previous_state_json TEXT,
        new_state_json      TEXT,
        reason              TEXT NOT NULL,
        confidence_tier     TEXT,
        related_claim_id    TEXT REFERENCES claims(id) ON DELETE SET NULL,
        created_at          TEXT NOT NULL
    );
    CREATE INDEX idx_model_revision_entries_revision ON model_revision_entries(model_revision_id);
    CREATE INDEX idx_model_revision_entries_type ON model_revision_entries(entity_type, change_type);
    CREATE INDEX idx_model_revision_entries_related_claim ON model_revision_entries(related_claim_id);
    """
}
