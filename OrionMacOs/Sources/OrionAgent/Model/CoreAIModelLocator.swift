import Foundation

/// Finds an exported Core AI language-model bundle on disk (Docs/18 M1).
///
/// Core AI weights are never auto-downloaded -- they're produced by
/// `scripts/coreai/export-qwen3.sh`, which writes `<root>/<variant>/`. Both sides share one
/// layout: `<root>` is `ORION_COREAI_MODEL_DIR` when set, else
/// `~/Library/Application Support/Orion/CoreAIModels`; `<variant>` is
/// `<registry-short-name>-<compression>` (e.g. `qwen3-8b-4bit`).
public enum CoreAIModelLocator {
    public static let environmentKey = "ORION_COREAI_MODEL_DIR"
    public static let defaultVariant = "qwen3-8b-4bit"

    /// `CustomStringConvertible` too, so `String(describing:)` -- how the app reports a failed
    /// ask or grade -- shows the export command rather than the enum case (Docs/18 M6).
    public enum LocatorError: Error, LocalizedError, CustomStringConvertible, Equatable {
        case bundleNotFound(URL, variant: String)

        public var errorDescription: String? {
            switch self {
            case .bundleNotFound(let url, let variant):
                return """
                    No Core AI model bundle at \(url.path) (expected a folder containing \
                    metadata.json). Export it with: \(CoreAIModelLocator.exportCommand(variant: variant))
                    """
            }
        }

        public var description: String { errorDescription ?? "Core AI model bundle not found" }
    }

    /// The command that produces `variant`'s bundle, relative to the repository root. Variants are
    /// `<model>-<compression>`; compression presets contain no `-`, so the last dash splits them.
    public static func exportCommand(variant: String) -> String {
        let dashed = variant.split(separator: "-")
        let model = dashed.count >= 3 ? dashed.dropLast().joined(separator: "-") : variant
        let compression = dashed.count >= 3 ? String(dashed.last!) : "4bit"
        return "OrionMacOs/scripts/coreai/export-qwen3.sh --model \(model) --compression \(compression)"
    }

    /// The bundle variants `roles` resolve to on `backend` (per `LocalModelRoles`) that aren't
    /// exported yet, deduplicated in role order -- what the app's model-setup notice lists before
    /// the first question fails on a missing bundle (Docs/18 M6).
    public static func missingVariants(
        for backend: LocalModelBackend, roles: [LocalModelRole],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var seen: Set<String> = []
        // The system model has no bundle to export (Docs/19 M1).
        guard case .coreAI = backend else { return [] }
        return roles.map { backend.resolved(for: $0).backend.variant }.filter { variant in
            guard seen.insert(variant).inserted else { return false }
            return (try? bundleURL(variant: variant, environment: environment)) == nil
        }
    }

    public static func rootDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Orion/CoreAIModels", isDirectory: true)
    }

    /// The bundle folder to pass to `CoreAILanguageModel(resourcesAt:)`. Checks only that the export
    /// finished (`metadata.json` is the last file the export writes); the bundle's own contents are
    /// validated by `CoreAILanguageModel` itself when it loads.
    public static func bundleURL(
        variant: String = defaultVariant,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let bundle = rootDirectory(environment: environment).appendingPathComponent(variant, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("metadata.json").path) else {
            throw LocatorError.bundleNotFound(bundle, variant: variant)
        }
        return bundle
    }
}
