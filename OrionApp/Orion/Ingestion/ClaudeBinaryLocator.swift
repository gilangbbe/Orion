import Foundation
import OrionAgent

/// **Real bug, found live**: "Architecture model failed: claude did not print a JSON wrapper on
/// stdout" turned out to mean `env claude ...` couldn't find `claude` at all, not that the CLI
/// itself failed. A GUI app (launched by Finder, `open`, or Xcode's own Run) inherits a minimal
/// `launchd` environment, not an interactive shell's `PATH` -- wherever a package manager (or the
/// official installer) put `claude` (`/opt/homebrew/bin`, `~/.npm-global/bin`, ...) is usually
/// absent from it. Every prior CLI invocation in this codebase (Phase 2's Python subprocess,
/// Phase 3's `orion-agent`, this phase's own `SemanticInvestigator` during development) ran from
/// a real Terminal shell, so this specific gap was never exercised until the real `.app` was
/// actually launched the way an end user launches it.
enum ClaudeBinaryLocator {
    /// Common absolute install locations, checked before shelling out to anything -- covers the
    /// vast majority of real installs without needing a subprocess at all.
    static let commonCandidates = [
        // The official installer's default location (`curl ... | bash` /
        // `npm install -g @anthropic-ai/claude-code` on some setups) -- confirmed as the real
        // install location on the machine this bug was found and fixed on; a bare `which claude`
        // in a non-login shell doesn't find it either, matching the GUI-app failure exactly.
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude",
        NSHomeDirectory() + "/.npm-global/bin/claude",
    ]

    /// Resolves an absolute path to the `claude` CLI. Checks common absolute paths first (fast,
    /// deterministic); falls back to asking a real **login** shell (`-l` sources
    /// `.zprofile`/`.zshrc`/etc., picking up nvm/asdf/a custom `PATH` export), which is slower but
    /// correct regardless of install location. Returns the bare name unchanged if nothing is
    /// found -- the same fallback behavior as before this fix, not a new failure mode; `env
    /// claude` will still be attempted and still fail the same honest way if `claude` truly isn't
    /// installed anywhere.
    static func resolve(
        candidates: [String] = commonCandidates,
        fileManager: FileManager = .default,
        loginShellLookup: () async -> String? = defaultLoginShellLookup
    ) async -> String {
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let resolved = await loginShellLookup(), !resolved.isEmpty {
            return resolved
        }
        return "claude"
    }

    static func defaultLoginShellLookup() async -> String? {
        guard
            let result = try? await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-l", "-c", "command -v claude"],
                timeout: 5
            ), result.exitCode == 0
        else { return nil }
        let path = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
