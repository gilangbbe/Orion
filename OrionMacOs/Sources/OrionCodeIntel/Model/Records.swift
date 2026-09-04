import Foundation
import GRDB

/// Shared GRDB configuration: Swift camelCase properties <-> snake_case columns, matching the
/// DDL in `Migrations.swift` and the JSON export contract.
public protocol OrionRecord: Codable, FetchableRecord, PersistableRecord {}

extension OrionRecord {
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .convertToSnakeCase
    }
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }
}

public enum AnalysisStatus: String, Codable, Sendable {
    case pending, running, succeeded, failed
}

/// One analyzed repository at one commit. `UNIQUE(local_path, commit_hash)`.
public struct RepositoryRecord: OrionRecord {
    public static let databaseTableName = "repositories"

    public var id: String
    public var sourceURL: String?
    public var localPath: String
    public var commitHash: String
    public var languages: [String]          // stored as JSON text by GRDB
    public var analysisStatus: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String, sourceURL: String?, localPath: String, commitHash: String,
        languages: [String], analysisStatus: AnalysisStatus, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.localPath = localPath
        self.commitHash = commitHash
        self.languages = languages
        self.analysisStatus = analysisStatus.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One invocation of the analyzer over a `(repository, commit)`.
public struct AnalysisRunRecord: OrionRecord {
    public static let databaseTableName = "analysis_runs"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var status: String
    public var startedAt: String
    public var finishedAt: String?
    public var orionVersion: String
    public var resolver: String                 // "scip-python@<ver>" | "none"
    public var grammarVersions: [String: String]
    public var toolVersions: [String: String]
    public var stageTimings: [String: Double]   // stage -> milliseconds
    public var fileCount: Int
    public var symbolCount: Int
    public var relationshipCount: Int
    public var diagnosticCount: Int
    public var error: String?
}

public struct FileRecord: OrionRecord {
    public static let databaseTableName = "files"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var path: String                 // repo-relative POSIX
    public var language: String?
    public var modulePath: String?          // dotted, e.g. starlette.applications
    public var sha256: String
    public var byteSize: Int
    public var lineCount: Int
    public var isTest: Bool
    public var isPackageInit: Bool
    public var parseOk: Bool
}

public enum ExternalDependencySource: String, Codable, Sendable {
    case pyproject, requirements, stdlib, inferred
}

public struct ExternalDependencyRecord: OrionRecord {
    public static let databaseTableName = "external_dependencies"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var name: String                 // best-known top-level import name
    public var distribution: String?        // pyproject / requirements distribution name
    public var source: String               // ExternalDependencySource
    public var versionSpec: String?
    public var isStdlib: Bool
    public var importCount: Int
}

public struct SymbolRecord: OrionRecord {
    public static let databaseTableName = "symbols"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var fileId: String
    public var componentId: String?          // Phase 2 placeholder, always nil
    public var parentSymbolId: String?
    public var name: String
    public var qualifiedName: String
    public var anchor: String                // benchmark form: path::Dotted.Name
    public var kind: String
    public var startLine: Int
    public var startCol: Int
    public var endLine: Int
    public var endCol: Int
    public var startByte: Int
    public var endByte: Int
    public var signature: String?
    public var docstring: String?
    public var decorators: [String]          // stored as JSON text
    public var visibility: String
    public var isExported: Bool
    public var redirectsTo: String?
    public var epistemicType: String
}

public struct RelationshipRecord: OrionRecord {
    public static let databaseTableName = "relationships"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var relationshipType: String     // RelationshipType
    public var sourceSymbolId: String?
    public var targetSymbolId: String?
    public var externalDependencyId: String?
    public var sourceRef: String?
    public var targetRef: String?
    public var provenance: String
    public var confidence: Double
    public var confidenceTier: String       // ConfidenceTier
    public var resolved: Bool
    public var epistemicType: String
    public var siteFileId: String?
    public var siteStartLine: Int?
    public var siteStartCol: Int?
    public var siteEndLine: Int?
    public var siteEndCol: Int?
}

public struct DiagnosticRecord: OrionRecord {
    public static let databaseTableName = "diagnostics"

    public var id: String
    public var repositoryId: String
    public var commitHash: String
    public var runId: String
    public var fileId: String?
    public var stage: String                // ingest|parse|symbols|imports|resolution|tests
    public var severity: String             // error|warning|info
    public var code: String
    public var message: String
    public var startLine: Int?
    public var startCol: Int?
    public var endLine: Int?
    public var endCol: Int?
}
