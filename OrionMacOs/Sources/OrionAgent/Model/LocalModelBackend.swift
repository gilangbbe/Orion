import Foundation

/// Which Core AI bundle serves the local model (Docs/18 M2). Since Docs/18 M6 Core AI is the only
/// local runtime -- MLX was removed after the M3 gate passed -- so a backend is just a bundle
/// variant, and `LocalModelRoles` decides which variant each role actually loads.
public enum LocalModelBackend: Hashable, Sendable {
    /// A Core AI bundle `CoreAIModelLocator` resolves, e.g. `qwen3-8b-4bit`.
    case coreAI(variant: String)

    /// `coreai` | `coreai:<variant>`.
    public static let environmentKey = "ORION_LOCAL_BACKEND"

    public struct ParseError: Error, LocalizedError, Equatable {
        public let value: String
        public var errorDescription: String? {
            if value.trimmingCharacters(in: .whitespaces).lowercased() == "mlx" {
                return "The MLX backend was removed (Docs/18 M6); use coreai or coreai:<variant>."
            }
            return "Unknown local backend \"\(value)\" (expected coreai or coreai:<variant>)."
        }
    }

    public init(parsing value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "coreai" {
            self = .coreAI(variant: CoreAIModelLocator.defaultVariant)
            return
        }
        let prefix = "coreai:"
        guard trimmed.lowercased().hasPrefix(prefix), trimmed.count > prefix.count else {
            throw ParseError(value: value)
        }
        self = .coreAI(variant: String(trimmed.dropFirst(prefix.count)))
    }

    /// `ORION_LOCAL_BACKEND` if set, else `nil`. Throws on an unparseable value rather than
    /// silently falling back, so a typo can't quietly run the wrong model.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LocalModelBackend? {
        guard let value = environment[environmentKey], !value.isEmpty else { return nil }
        return try LocalModelBackend(parsing: value)
    }

    /// The default Core AI bundle, `qwen3-8b-4bit` (with `LocalModelRoles.recommended`).
    public static let defaultCoreAI = LocalModelBackend.coreAI(variant: CoreAIModelLocator.defaultVariant)

    /// The default for callers with no way to surface a configuration error (the app): the
    /// environment's backend when it parses, else `defaultCoreAI`.
    public static var `default`: LocalModelBackend {
        ((try? fromEnvironment()) ?? nil) ?? defaultCoreAI
    }

    public var variant: String {
        switch self {
        case .coreAI(let variant): return variant
        }
    }

    /// Matches the loaded model's `AgentModel.modelIdentifier`, without loading it.
    public var modelIdentifier: String { "coreai:\(variant)" }
}
