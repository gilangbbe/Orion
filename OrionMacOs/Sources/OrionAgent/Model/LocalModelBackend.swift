import Foundation

/// Which model serves the local calls. On the Mac that's a Core AI bundle (Docs/18 M2; since M6
/// the only Mac runtime), and `LocalModelRoles` decides which variant each role loads. On iOS it's
/// the on-device system model (Docs/19 M1), which the Mac can also run for development.
public enum LocalModelBackend: Hashable, Sendable {
    /// A Core AI bundle `CoreAIModelLocator` resolves, e.g. `qwen3-8b-4bit`. Mac only.
    case coreAI(variant: String)
    /// `SystemLanguageModel.default` (Docs/19 M1). No bundle and no per-role variants; which model
    /// it is depends on the device -- AFM 3 Core (4,096 tokens) on iPhone 17, AFM 3 Core Advanced
    /// (8,192) on the Mac (Docs/19 M0), so Mac runs don't predict the phone.
    case system

    /// `coreai` | `coreai:<variant>` | `system`.
    public static let environmentKey = "ORION_LOCAL_BACKEND"

    public struct ParseError: Error, LocalizedError, Equatable {
        public let value: String
        public var errorDescription: String? {
            if value.trimmingCharacters(in: .whitespaces).lowercased() == "mlx" {
                return "The MLX backend was removed (Docs/18 M6); use coreai, coreai:<variant> or system."
            }
            return "Unknown local backend \"\(value)\" (expected coreai, coreai:<variant> or system)."
        }
    }

    public init(parsing value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "system" {
            self = .system
            return
        }
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

    /// The platform's own model: Core AI on the Mac, the system model on iOS, where Core AI isn't
    /// linked (Docs/19 M1).
    public static var platformDefault: LocalModelBackend {
        #if os(macOS)
        defaultCoreAI
        #else
        .system
        #endif
    }

    /// The default for callers with no way to surface a configuration error (the apps): the
    /// environment's backend when it parses, else `platformDefault`.
    public static var `default`: LocalModelBackend {
        ((try? fromEnvironment()) ?? nil) ?? platformDefault
    }

    /// The Core AI bundle variant; `"system"` for the system model, which has none.
    public var variant: String {
        switch self {
        case .coreAI(let variant): return variant
        case .system: return "system"
        }
    }

    /// Matches the loaded model's `AgentModel.modelIdentifier`, without loading it. The system
    /// model's names its variant (`system:AFM 3 Core`), because it differs by device.
    public var modelIdentifier: String {
        switch self {
        case .coreAI(let variant): return "coreai:\(variant)"
        case .system: return "system:\(SystemModelInfo.variantName)"
        }
    }
}
