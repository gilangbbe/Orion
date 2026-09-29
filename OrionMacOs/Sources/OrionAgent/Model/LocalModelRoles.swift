import Foundation

/// The jobs Orion gives the local model (Docs/18 M4). Each can run on its own Core AI variant and
/// reasoning setting, because a role that holds quality on a smaller or non-thinking model
/// shouldn't pay for the largest one.
public enum LocalModelRole: String, CaseIterable, Sendable {
    /// Depth 1/2 answers (direct / `NativeToolLoop`).
    case answering
    /// Band 1/2 teaching question drafts (`LocalTeachingDrafter`).
    case drafting
    /// Per-criterion rubric verdicts (`LocalCriterionJudge`).
    case judging
    /// The §7.4 pairwise same-idea tripwire (`LocalAnswerComparer`).
    case comparing
}

/// Whether a reasoning model thinks before answering. `off` maps to
/// `ContextOptions(reasoningLevel: .custom("none"))`, which `CoreAILanguageModel` turns into the
/// chat template's `enable_thinking: false`.
public enum ReasoningMode: String, Sendable {
    case on
    case off
}

/// One role's model: a Core AI variant (`nil` = the backend's own) and a reasoning mode.
public struct LocalModelSetting: Hashable, Sendable {
    public var variant: String?
    public var reasoning: ReasoningMode

    public init(variant: String? = nil, reasoning: ReasoningMode = .on) {
        self.variant = variant
        self.reasoning = reasoning
    }
}

/// Role → model table for the Core AI backend (Docs/18 M4).
///
/// `ORION_LOCAL_ROLES` overrides the built-in table, as comma-separated `role=setting` pairs, where
/// `role` is a `LocalModelRole` or `*` (every role not named otherwise) and `setting` is
/// `variant`, `on|off`, or `variant:on|off` -- e.g. `*=qwen3-4b-4bit:off,answering=qwen3-8b-4bit`.
public struct LocalModelRoles: Equatable, Sendable {
    public static let environmentKey = "ORION_LOCAL_ROLES"

    public private(set) var settings: [LocalModelRole: LocalModelSetting]

    public init(_ settings: [LocalModelRole: LocalModelSetting] = [:]) {
        self.settings = settings
    }

    /// Every role on the backend's variant with reasoning on -- the behaviour before M4.
    public static let uniform = LocalModelRoles()

    /// What Core AI runs with when `ORION_LOCAL_ROLES` is unset: M4's per-role choice (short run,
    /// `Agent Feasibility Study/results/coreai_backend/m4/`).
    ///
    /// - answering: `qwen3-4b-4bit`, thinking off -- p50 45 s vs 99 s for 8B thinking, with a
    ///   hand-graded 7.5 vs 8.0 / 20 on the 10-question sample (within noise).
    /// - judging, comparing: the backend's variant (8B), thinking **on**. Without thinking the judge
    ///   calls ~95% of criteria (misconceptions included) "met": κ 0.04 (8B) / 0.08 (4B) vs 0.78.
    ///   4B with thinking matched κ (0.80) but had lower verdict accuracy (0.60 vs 0.83) and one
    ///   judge call that never produced an answer.
    /// - drafting: unchanged (8B, thinking on) -- not measured in the short run.
    public static let recommended = LocalModelRoles([
        .answering: LocalModelSetting(variant: "qwen3-4b-4bit", reasoning: .off)
    ])

    /// The table `backend` runs with: `ORION_LOCAL_ROLES` when it parses; else `recommended` for the
    /// default Core AI bundle (plain `coreai`); else `uniform`, so an explicit `coreai:<variant>`
    /// really runs every role on that variant. Lenient, for callers with no way to surface a
    /// configuration error (the app); the CLI validates the environment up front instead.
    public static func current(for backend: LocalModelBackend) -> LocalModelRoles {
        if let fromEnvironment = (try? fromEnvironment()) ?? nil { return fromEnvironment }
        return backend == .defaultCoreAI ? recommended : uniform
    }

    public func setting(for role: LocalModelRole) -> LocalModelSetting {
        settings[role] ?? LocalModelSetting()
    }

    public struct ParseError: Error, LocalizedError, Equatable {
        public let value: String
        public var errorDescription: String? {
            "Invalid \(LocalModelRoles.environmentKey) entry \"\(value)\" (expected role=variant, "
                + "role=on|off or role=variant:on|off, with role one of "
                + "\(LocalModelRole.allCases.map(\.rawValue).joined(separator: ", ")) or *)."
        }
    }

    public init(parsing value: String) throws {
        var wildcard: LocalModelSetting?
        var named: [LocalModelRole: LocalModelSetting] = [:]
        for entry in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !entry.isEmpty {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let setting = Self.parseSetting(parts[1]) else {
                throw ParseError(value: entry)
            }
            if parts[0] == "*" {
                wildcard = setting
            } else if let role = LocalModelRole(rawValue: parts[0]) {
                named[role] = setting
            } else {
                throw ParseError(value: entry)
            }
        }
        var settings: [LocalModelRole: LocalModelSetting] = [:]
        for role in LocalModelRole.allCases {
            settings[role] = named[role] ?? wildcard
        }
        self.init(settings.compactMapValues { $0 })
    }

    /// `ORION_LOCAL_ROLES` if set, else `nil`; throws on an unparseable value.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LocalModelRoles? {
        guard let value = environment[environmentKey], !value.isEmpty else { return nil }
        return try LocalModelRoles(parsing: value)
    }

    private static func parseSetting(_ raw: String) -> LocalModelSetting? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        switch parts.count {
        case 1:
            if let mode = ReasoningMode(rawValue: parts[0]) { return LocalModelSetting(reasoning: mode) }
            return parts[0].isEmpty ? nil : LocalModelSetting(variant: parts[0])
        case 2:
            guard let mode = ReasoningMode(rawValue: parts[1]) else { return nil }
            return LocalModelSetting(variant: parts[0].isEmpty ? nil : parts[0], reasoning: mode)
        default:
            return nil
        }
    }
}

/// What one role actually loads: a backend with its variant resolved, plus a reasoning mode.
public struct ResolvedLocalModel: Hashable, Sendable {
    public let backend: LocalModelBackend
    public let reasoning: ReasoningMode

    /// `AgentModel.modelIdentifier` for this model, e.g. `coreai:qwen3-4b-4bit+nothink`.
    public var modelIdentifier: String {
        backend.modelIdentifier + (reasoning == .off ? "+nothink" : "")
    }
}

extension LocalModelBackend {
    /// The model `role` runs on under `roles` (`nil`: `LocalModelRoles.current(for: self)`).
    public func resolved(for role: LocalModelRole, roles: LocalModelRoles? = nil) -> ResolvedLocalModel {
        let setting = (roles ?? LocalModelRoles.current(for: self)).setting(for: role)
        return ResolvedLocalModel(
            backend: .coreAI(variant: setting.variant ?? variant), reasoning: setting.reasoning)
    }

    public func modelIdentifier(for role: LocalModelRole, roles: LocalModelRoles? = nil) -> String {
        resolved(for: role, roles: roles).modelIdentifier
    }
}
