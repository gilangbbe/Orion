import ArgumentParser
import OrionAgent

/// `--judge-output` for the commands that grade teaching answers (Docs/18 M5).
struct JudgeOutputOption: ParsableArguments {
    @Option(
        name: .customLong("judge-output"),
        help: """
            How the local grader returns verdicts: text (thinking, then a tolerant JSON parse) or \
            guided (two guided turns, for Core AI) or single (one guided turn, for the system model). Falls back to ORION_JUDGE_OUTPUT, then text.
            """
    )
    var judgeOutput: String?

    func resolve() throws -> JudgeOutput {
        guard let judgeOutput else { return .current }
        guard let parsed = JudgeOutput(rawValue: judgeOutput.lowercased()) else {
            throw ValidationError("--judge-output must be text, guided or single (got \(judgeOutput))")
        }
        return parsed
    }
}
