import Foundation

/// Summary of the latest run in a Code Graph DB. Rendered by `orion-index stats`.
public struct StatsReport: Codable, Sendable {
    public var databasePath: String
    public var repositoryId: String?
    public var localPath: String?
    public var commitHash: String?
    public var runId: String?
    public var status: String?
    public var resolver: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var fileCount: Int
    public var pythonFileCount: Int
    public var filesByLanguage: [String: Int]
    public var parseOkCount: Int
    public var externalDependencyCount: Int
    public var symbolCount: Int
    public var relationshipCount: Int
    public var diagnosticCount: Int
    public var stageTimingsMs: [String: Double]
}

public enum StatsReporter {
    public static func build(database: OrionDatabase, commitHash: String?) throws -> StatsReport {
        let store = Store(database)
        var report = StatsReport(
            databasePath: database.path, repositoryId: nil, localPath: nil, commitHash: nil,
            runId: nil, status: nil, resolver: nil, startedAt: nil, finishedAt: nil, fileCount: 0,
            pythonFileCount: 0, filesByLanguage: [:], parseOkCount: 0,
            externalDependencyCount: 0, symbolCount: 0, relationshipCount: 0,
            diagnosticCount: 0, stageTimingsMs: [:]
        )

        guard let run = try store.latestRun(commitHash: commitHash) else { return report }

        let byLanguage = try store.fileLanguageBreakdown(runId: run.id)
        report.repositoryId = run.repositoryId
        report.commitHash = run.commitHash
        report.runId = run.id
        report.status = run.status
        report.resolver = run.resolver
        report.startedAt = run.startedAt
        report.finishedAt = run.finishedAt
        report.fileCount = try store.count("files", runId: run.id)
        report.pythonFileCount = byLanguage["python"] ?? 0
        report.filesByLanguage = byLanguage
        report.parseOkCount = try store.parseOkCount(runId: run.id)
        report.externalDependencyCount = try store.count("external_dependencies", runId: run.id)
        report.symbolCount = try store.count("symbols", runId: run.id)
        report.relationshipCount = try store.count("relationships", runId: run.id)
        report.diagnosticCount = try store.count("diagnostics", runId: run.id)
        report.stageTimingsMs = run.stageTimings

        report.localPath = try database.dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT local_path FROM repositories WHERE id = ?",
                arguments: [run.repositoryId]
            )
        }
        return report
    }
}
