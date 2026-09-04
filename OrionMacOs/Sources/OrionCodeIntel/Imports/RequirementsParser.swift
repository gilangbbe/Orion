import Foundation

/// Parses `requirements*.txt` files. Line-oriented PEP 508; `-r`/`-e`/`--hash` option lines
/// and comments are ignored. (Starlette has none, but pip-style repos do.)
public enum RequirementsParser {
    public static func parse(text: String, group: String = "requirements") -> [DeclaredDependency] {
        var seen: Set<String> = []
        var out: [DeclaredDependency] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let dep = PEP508.parse(String(rawLine), source: .requirements, group: group)
            else { continue }
            if seen.insert(dep.distribution).inserted { out.append(dep) }
        }
        return out.sorted { $0.distribution < $1.distribution }
    }
}
