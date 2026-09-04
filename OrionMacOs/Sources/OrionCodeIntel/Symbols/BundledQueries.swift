import Foundation

/// Loads the `.scm` query files shipped inside the package bundle
/// (`Sources/OrionCodeIntel/Symbols/Queries/`).
public enum BundledQueries {
    /// Raw text of `<name>.scm`.
    public static func source(named name: String) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "scm", subdirectory: "Queries"
        ) ?? Bundle.module.url(forResource: name, withExtension: "scm") else {
            throw LanguageSupportError.queryResourceMissing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
