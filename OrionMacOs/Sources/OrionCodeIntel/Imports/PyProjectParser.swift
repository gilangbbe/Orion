import Foundation
import TOMLDecoder

/// Extracts declared dependencies from `pyproject.toml`. Supports PEP 621
/// (`[project].dependencies`, `[project.optional-dependencies]`) and PEP 735
/// (`[dependency-groups]`). Poetry's `[tool.poetry.dependencies]` table is not yet handled
/// (no fixture needs it — add when one does).
public enum PyProjectParser {

    /// `[project].name` (PEP 621), if present.
    public static func projectName(tomlText: String) -> String? {
        (try? TOMLDecoder().decode(Doc.self, from: tomlText))?.project?.name
    }

    public static func parse(tomlText: String) throws -> [DeclaredDependency] {
        let doc = try TOMLDecoder().decode(Doc.self, from: tomlText)
        let ownName = doc.project?.name.map(PEP508.normalize)

        var byDistribution: [String: DeclaredDependency] = [:]
        func add(_ entries: [Lenient], source: ExternalDependencySource, group: String) {
            for entry in entries {
                guard let raw = entry.string,
                      let dep = PEP508.parse(raw, source: source, group: group)
                else { continue }
                if let ownName, dep.distribution == ownName { continue }
                if let existing = byDistribution[dep.distribution] {
                    // Prefer an entry that carries a version spec.
                    if existing.versionSpec == nil, dep.versionSpec != nil {
                        byDistribution[dep.distribution] = dep
                    }
                } else {
                    byDistribution[dep.distribution] = dep
                }
            }
        }

        add(doc.project?.dependencies ?? [], source: .pyproject, group: "runtime")
        for (extra, entries) in doc.project?.optionalDependencies ?? [:] {
            add(entries, source: .pyproject, group: "optional:\(extra)")
        }
        for (name, entries) in doc.dependencyGroups ?? [:] {
            add(entries, source: .pyproject, group: "dev:\(name)")
        }

        return byDistribution.values.sorted { $0.distribution < $1.distribution }
    }

    // MARK: TOML shapes

    private struct Doc: Decodable {
        let project: Project?
        let dependencyGroups: [String: [Lenient]]?

        enum CodingKeys: String, CodingKey {
            case project
            case dependencyGroups = "dependency-groups"
        }
    }

    private struct Project: Decodable {
        let name: String?
        let dependencies: [Lenient]?
        let optionalDependencies: [String: [Lenient]]?

        enum CodingKeys: String, CodingKey {
            case name
            case dependencies
            case optionalDependencies = "optional-dependencies"
        }
    }
}

/// Decodes a TOML value that is *usually* a string; anything else (e.g. a PEP 735
/// `{ include-group = "x" }` table) decodes to `nil` and is skipped.
struct Lenient: Decodable {
    let string: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        string = try? container.decode(String.self)
    }
}
