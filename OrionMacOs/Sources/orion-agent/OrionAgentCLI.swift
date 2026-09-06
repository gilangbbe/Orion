import ArgumentParser
import OrionAgent

@main
struct OrionAgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orion-agent",
        abstract: "Local MLX agent for Orion (Phase 3).",
        discussion: """
        Routes a developer question through a depth model to local Qwen3-8B-4bit reasoning,
        deterministic Code Graph tools, or a delegated Claude Code investigation. See
        Docs/12_phase3_mlx_agent.md.
        """,
        version: OrionAgent.version,
        subcommands: [Ask.self, Classify.self]
    )
}
