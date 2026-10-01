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

    public init(
        id: String, repositoryId: String, commitHash: String, status: String, startedAt: String,
        finishedAt: String? = nil, orionVersion: String, resolver: String,
        grammarVersions: [String: String], toolVersions: [String: String],
        stageTimings: [String: Double], fileCount: Int, symbolCount: Int, relationshipCount: Int,
        diagnosticCount: Int, error: String? = nil
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.orionVersion = orionVersion
        self.resolver = resolver
        self.grammarVersions = grammarVersions
        self.toolVersions = toolVersions
        self.stageTimings = stageTimings
        self.fileCount = fileCount
        self.symbolCount = symbolCount
        self.relationshipCount = relationshipCount
        self.diagnosticCount = diagnosticCount
        self.error = error
    }
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

    public init(
        id: String, repositoryId: String, commitHash: String, runId: String, path: String,
        language: String? = nil, modulePath: String? = nil, sha256: String, byteSize: Int,
        lineCount: Int, isTest: Bool, isPackageInit: Bool, parseOk: Bool
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.path = path
        self.language = language
        self.modulePath = modulePath
        self.sha256 = sha256
        self.byteSize = byteSize
        self.lineCount = lineCount
        self.isTest = isTest
        self.isPackageInit = isPackageInit
        self.parseOk = parseOk
    }
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

    public init(
        id: String, repositoryId: String, commitHash: String, runId: String, name: String,
        distribution: String? = nil, source: String, versionSpec: String? = nil, isStdlib: Bool,
        importCount: Int
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.name = name
        self.distribution = distribution
        self.source = source
        self.versionSpec = versionSpec
        self.isStdlib = isStdlib
        self.importCount = importCount
    }
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

    public init(
        id: String, repositoryId: String, commitHash: String, runId: String, fileId: String,
        componentId: String? = nil, parentSymbolId: String? = nil, name: String,
        qualifiedName: String, anchor: String, kind: String, startLine: Int, startCol: Int,
        endLine: Int, endCol: Int, startByte: Int, endByte: Int, signature: String? = nil,
        docstring: String? = nil, decorators: [String], visibility: String, isExported: Bool,
        redirectsTo: String? = nil, epistemicType: String
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.fileId = fileId
        self.componentId = componentId
        self.parentSymbolId = parentSymbolId
        self.name = name
        self.qualifiedName = qualifiedName
        self.anchor = anchor
        self.kind = kind
        self.startLine = startLine
        self.startCol = startCol
        self.endLine = endLine
        self.endCol = endCol
        self.startByte = startByte
        self.endByte = endByte
        self.signature = signature
        self.docstring = docstring
        self.decorators = decorators
        self.visibility = visibility
        self.isExported = isExported
        self.redirectsTo = redirectsTo
        self.epistemicType = epistemicType
    }
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

    public init(
        id: String, repositoryId: String, commitHash: String, runId: String,
        relationshipType: String, sourceSymbolId: String? = nil, targetSymbolId: String? = nil,
        externalDependencyId: String? = nil, sourceRef: String? = nil, targetRef: String? = nil,
        provenance: String, confidence: Double, confidenceTier: String, resolved: Bool,
        epistemicType: String, siteFileId: String? = nil, siteStartLine: Int? = nil,
        siteStartCol: Int? = nil, siteEndLine: Int? = nil, siteEndCol: Int? = nil
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.relationshipType = relationshipType
        self.sourceSymbolId = sourceSymbolId
        self.targetSymbolId = targetSymbolId
        self.externalDependencyId = externalDependencyId
        self.sourceRef = sourceRef
        self.targetRef = targetRef
        self.provenance = provenance
        self.confidence = confidence
        self.confidenceTier = confidenceTier
        self.resolved = resolved
        self.epistemicType = epistemicType
        self.siteFileId = siteFileId
        self.siteStartLine = siteStartLine
        self.siteStartCol = siteStartCol
        self.siteEndLine = siteEndLine
        self.siteEndCol = siteEndCol
    }
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

    public init(
        id: String, repositoryId: String, commitHash: String, runId: String, fileId: String? = nil,
        stage: String, severity: String, code: String, message: String, startLine: Int? = nil,
        startCol: Int? = nil, endLine: Int? = nil, endCol: Int? = nil
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.commitHash = commitHash
        self.runId = runId
        self.fileId = fileId
        self.stage = stage
        self.severity = severity
        self.code = code
        self.message = message
        self.startLine = startLine
        self.startCol = startCol
        self.endLine = endLine
        self.endCol = endCol
    }
}
