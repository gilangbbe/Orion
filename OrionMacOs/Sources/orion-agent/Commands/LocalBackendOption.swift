import ArgumentParser
import OrionAgent

/// `--local-backend` for every command that runs the local model (Docs/18 M2).
struct LocalBackendOption: ParsableArguments {
    @Option(
        name: .customLong("local-backend"),
        help: """
            Local model: coreai (default: qwen3-8b-4bit with the measured per-role table), \
            coreai:<variant> (every role on that bundle), or system (the on-device Apple system \
            model -- the iOS companion's model family, but a larger variant on the Mac, Docs/19). \
            Falls back to ORION_LOCAL_BACKEND; ORION_LOCAL_ROLES picks a variant and reasoning mode \
            per role (ignored for system).
            """
    )
    var localBackend: String?

    func validate() throws {
        _ = try resolve()
        // Validate the role table here: past this point `LocalModelRoles.current(for:)` is lenient and
        // would silently fall back to the built-in table (Docs/18 M4).
        do {
            _ = try LocalModelRoles.fromEnvironment()
        } catch let error as LocalModelRoles.ParseError {
            throw ValidationError(error.errorDescription ?? "invalid \(LocalModelRoles.environmentKey)")
        }
    }

    func resolve() throws -> LocalModelBackend {
        do {
            if let localBackend { return try LocalModelBackend(parsing: localBackend) }
            return try LocalModelBackend.fromEnvironment() ?? .defaultCoreAI
        } catch let error as LocalModelBackend.ParseError {
            throw ValidationError(error.errorDescription ?? "invalid local backend")
        }
    }
}
