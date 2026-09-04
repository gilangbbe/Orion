import Foundation
import GRDB

/// The Code Graph schema. One migration per schema change, never edited after commit.
/// Phase 2 semantic tables (`components`, `claims`, `evidence`, …) arrive as later `v2_*`
/// migrations — the `symbols.component_id` / `epistemic_type` columns already leave room.
public enum OrionMigrations {

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        registerV1(&migrator)
        return migrator
    }

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_phase1_schema") { db in
            try db.execute(sql: Self.v1SQL)
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
}
