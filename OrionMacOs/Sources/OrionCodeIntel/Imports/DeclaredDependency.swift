import Foundation

/// A dependency declared in project metadata (`pyproject.toml` / `requirements*.txt`),
/// before any `import` statement has been seen. M4 reconciles these with actual imports and
/// fills `import_count`.
public struct DeclaredDependency: Equatable, Sendable {
    /// PEP 503 normalized distribution name (lowercase; runs of `-_.` collapsed to `-`).
    public let distribution: String
    /// Name as written in the manifest.
    public let rawName: String
    /// Version specifier, e.g. `>=3.6.2,<5`; `nil` when unconstrained or a URL requirement.
    public let versionSpec: String?
    public let extras: [String]
    /// PEP 508 environment marker after `;`, if any.
    public let marker: String?
    public let source: ExternalDependencySource
    /// `runtime`, `optional:<extra>`, or `dev:<group>` — informational (not persisted).
    public let group: String

    /// Best-effort top-level import name (M4 replaces this with the observed one).
    public var importNameGuess: String {
        distribution.replacingOccurrences(of: "-", with: "_")
    }
}

public enum PEP508 {
    /// Normalize a distribution name per PEP 503.
    public static func normalize(_ name: String) -> String {
        var out = ""
        var lastWasSep = false
        for ch in name.lowercased() {
            if ch == "-" || ch == "_" || ch == "." {
                if !lastWasSep { out.append("-") }
                lastWasSep = true
            } else {
                out.append(ch)
                lastWasSep = false
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Parse one PEP 508 requirement string. Returns `nil` for blank/comment lines.
    public static func parse(
        _ raw: String, source: ExternalDependencySource, group: String
    ) -> DeclaredDependency? {
        var line = raw
        if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // Options lines in requirements.txt (-r, -e, --hash=...) are not distributions.
        if line.hasPrefix("-") { return nil }

        var marker: String?
        if let semi = line.firstIndex(of: ";") {
            marker = String(line[line.index(after: semi)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            line = String(line[line.startIndex..<semi])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // URL requirement: "name @ https://…"
        if let at = line.firstIndex(of: "@") {
            let name = String(line[line.startIndex..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ident = leadingIdentifier(name) else { return nil }
            return DeclaredDependency(
                distribution: normalize(ident.name), rawName: ident.name,
                versionSpec: nil, extras: ident.extras, marker: marker,
                source: source, group: group
            )
        }

        guard let ident = leadingIdentifier(line) else { return nil }
        var spec = String(line[ident.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.hasPrefix("(") && spec.hasSuffix(")") {
            spec = String(spec.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return DeclaredDependency(
            distribution: normalize(ident.name), rawName: ident.name,
            versionSpec: spec.isEmpty ? nil : spec, extras: ident.extras, marker: marker,
            source: source, group: group
        )
    }

    private struct Identifier { let name: String; let extras: [String]; let endIndex: String.Index }

    private static func leadingIdentifier(_ s: String) -> Identifier? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var idx = s.startIndex
        var name = ""
        while idx < s.endIndex, allowed.contains(s[idx]) {
            name.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !name.isEmpty else { return nil }

        var extras: [String] = []
        // optional "[extra1, extra2]"
        var probe = idx
        while probe < s.endIndex, s[probe] == " " { probe = s.index(after: probe) }
        if probe < s.endIndex, s[probe] == "[", let close = s[probe...].firstIndex(of: "]") {
            extras = s[s.index(after: probe)..<close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            idx = s.index(after: close)
        }
        return Identifier(name: name, extras: extras, endIndex: idx)
    }
}
