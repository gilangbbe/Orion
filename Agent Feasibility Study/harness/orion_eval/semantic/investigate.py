"""Claude Code CLI bridge (Docs/11_phase2_semantic_analysis.md M1). Shells out to the `claude`
CLI in headless mode to perform one whole-repo semantic-grouping investigation.

Flags confirmed against `claude --version` 2.1.260 / `claude --help` (2026-09-04). CLI flags
are not a stable API surface here -- re-check `claude --help` if invocation starts failing,
and update `build_command()` in one place.

Read-only by construction: `--tools` hard-restricts the whole session to Read/Grep/Glob (no
Bash, no Edit/Write -- the session literally has no tool that can mutate anything), so
`--permission-mode bypassPermissions` is safe here and necessary for headless execution (no
human is present to answer a permission prompt). `--json-schema` asks the CLI to constrain its
final answer to `SEMANTIC_SCHEMA` directly; `extract_semantic_json` + `validate_semantic` are
still run against the result unconditionally -- nothing from an LLM is trusted just because a
flag asked for it (Docs/01 non-goals: "Treating LLM output as ground truth").
"""
from __future__ import annotations

import json
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .schema import (
    SCHEMA_HINT,
    SCHEMA_VERSION,
    cli_json_schema,
    extract_semantic_json,
    validate_semantic,
)

DEFAULT_MODEL = "claude-sonnet-5"      # pinned explicitly -- never float on a CLI default
DEFAULT_MAX_BUDGET_USD = 2.00          # `claude` enforces this itself via --max-budget-usd
DEFAULT_TIMEOUT_SECONDS = 900          # wall-clock backstop; this CLI version has no --max-turns
READ_ONLY_TOOLS = "Read,Grep,Glob"     # the entire allowed tool set -- no Bash, no Edit/Write

SYSTEM_PROMPT_TEMPLATE = """\
You are investigating a Python repository to reconstruct its semantic architecture for a tool
called Orion.

You have read-only tools (Read, Grep, Glob) over the repository at the current working
directory. A directory at {export_dir} holds a deterministically-extracted Code Graph:
`code_graph.json` is a compact skeleton (modules, classes, import matrix, entrypoints, test
map); `symbols.jsonl` lists every symbol with its exact `anchor`; `relationships.jsonl` lists
every resolved import/call/inheritance edge. Read `code_graph.json` first -- it is your map of
the repository, already fact-checked; you do not need to re-derive it from scratch, only use it
to decide where to look with Read/Grep for the semantic judgment a deterministic tool cannot
make.

Task: group the repository's symbols into a small number of coherent architectural components
(for example "Routing", "Middleware", "Requests/Responses" -- names specific to this
repository, not a generic template), each with a short description, an architectural role, and
the member symbols that belong to it. Then identify the most important relationships between
components, and a handful of specific, evidence-backed claims about how the system behaves.

Rules:
1. Every `members` entry and every claim's `evidence` entry MUST be an anchor copied verbatim
   from `symbols.jsonl`'s `anchor` field ("<path>::<Dotted.Name>" form, or a bare path for a
   module symbol). Do not invent an anchor, guess its spelling, paraphrase it, or cite a line
   number instead -- an anchor that does not match exactly will be rejected and the finding
   discarded, however plausible the underlying observation was.
2. `claim_type` must be INTERPRETATION (a semantic reading of what evidenced code does) or
   INFERENCE (a conclusion reached by combining multiple facts). Never claim FACT -- that tier
   is reserved for the deterministic extraction that already produced code_graph.json.
3. If something seems architecturally important but you cannot ground it in a specific symbol,
   put it in `uncertainties` as plain text instead of inventing evidence for it. An honest
   uncertainty is a correct, valued outcome.
4. Prefer a small number of well-evidenced components over many thin or overlapping ones.

Return your final answer as a single JSON object with exactly this shape (schema_version must
be exactly "{schema_version}"):
{schema_hint}
"""


@dataclass
class InvestigationResult:
    ok: bool                       # True iff a schema-valid candidate was extracted
    candidate: dict | None         # the phase2.v1 object, even if invalid (kept for inspection)
    candidate_errors: list[str]
    extraction_method: str         # "structured_output" | "clean" | "fenced" | "braces" | "none"
    outcome: str                   # "verified" | "unverified" | "incomplete" | "rejected"
    wrapper: dict                  # the raw `claude --output-format json` envelope
    session_id: str | None
    model_used: str | None
    num_turns: int | None
    total_cost_usd: float | None
    duration_ms: float | None
    command: list[str]
    stderr_tail: str


class ClaudeInvestigator:
    """One headless Claude Code CLI investigation over a repository checkout, standing in for
    the "MLX Agent invokes Claude Code" step of Docs/06_claude_code_integration.md until
    Phase 3's agent exists."""

    def __init__(
        self,
        repo_root: Path,
        export_dir: Path,
        *,
        model: str = DEFAULT_MODEL,
        max_budget_usd: float = DEFAULT_MAX_BUDGET_USD,
        timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
        claude_bin: str | None = None,
    ) -> None:
        self.repo_root = Path(repo_root).resolve()
        self.export_dir = Path(export_dir).resolve()
        self.model = model
        self.max_budget_usd = max_budget_usd
        self.timeout_seconds = timeout_seconds
        self.claude_bin = claude_bin or shutil.which("claude") or "claude"

    def build_prompt(self) -> str:
        return SYSTEM_PROMPT_TEMPLATE.format(
            export_dir=self.export_dir, schema_version=SCHEMA_VERSION, schema_hint=SCHEMA_HINT,
        )

    def build_command(self, prompt: str) -> list[str]:
        # Options first, prompt last: `-p`/`--print` is a boolean flag (not `-p <value>`), so
        # ordering the positional prompt after every option avoids any ambiguity about what it
        # binds to.
        return [
            self.claude_bin,
            "-p",
            "--output-format", "json",
            "--model", self.model,
            "--tools", READ_ONLY_TOOLS,
            "--permission-mode", "bypassPermissions",
            "--max-budget-usd", str(self.max_budget_usd),
            "--add-dir", str(self.export_dir),
            "--json-schema", json.dumps(cli_json_schema()),
            "--no-session-persistence",
            prompt,
        ]

    def run(self) -> InvestigationResult:
        prompt = self.build_prompt()
        cmd = self.build_command(prompt)
        t0 = time.time()

        try:
            proc = subprocess.run(
                cmd, cwd=self.repo_root, capture_output=True, text=True,
                timeout=self.timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            return InvestigationResult(
                ok=False, candidate=None, candidate_errors=["wall-clock timeout"],
                extraction_method="none", outcome="incomplete", wrapper={},
                session_id=None, model_used=self.model, num_turns=None, total_cost_usd=None,
                duration_ms=(time.time() - t0) * 1000, command=cmd,
                stderr_tail=_tail(exc.stderr),
            )

        stderr_tail = _tail(proc.stderr)
        try:
            wrapper = json.loads(proc.stdout) if proc.stdout else {}
        except json.JSONDecodeError:
            wrapper = {}
        if not isinstance(wrapper, dict) or not wrapper:
            return InvestigationResult(
                ok=False, candidate=None,
                candidate_errors=[
                    f"claude did not print a JSON wrapper on stdout (exit {proc.returncode})"
                ],
                extraction_method="none", outcome="rejected", wrapper={},
                session_id=None, model_used=self.model, num_turns=None, total_cost_usd=None,
                duration_ms=(time.time() - t0) * 1000, command=cmd, stderr_tail=stderr_tail,
            )

        # `--json-schema` makes `structured_output` already a parsed, schema-shaped object --
        # confirmed against a real run 2026-09-04. Prefer it; fall back to extracting `result`
        # text (clean/fenced/braces) if it's ever absent. Either way, `validate_semantic` is
        # still run unconditionally below -- a flag asking for structured output is not the
        # same as verifying it arrived.
        structured = wrapper.get("structured_output")
        if isinstance(structured, dict):
            candidate, method = structured, "structured_output"
        else:
            result_text = wrapper.get("result", "")
            candidate, method = extract_semantic_json(result_text if isinstance(result_text, str) else "")
        schema_ok, errors = validate_semantic(candidate)
        is_error = bool(wrapper.get("is_error"))

        outcome = (
            "rejected" if is_error or candidate is None
            else "verified" if schema_ok
            else "unverified"
        )

        return InvestigationResult(
            ok=schema_ok and not is_error,
            candidate=candidate,
            candidate_errors=errors,
            extraction_method=method,
            outcome=outcome,
            wrapper=wrapper,
            session_id=wrapper.get("session_id"),
            model_used=_dominant_model(wrapper) or self.model,
            num_turns=wrapper.get("num_turns"),
            total_cost_usd=wrapper.get("total_cost_usd"),
            duration_ms=wrapper.get("duration_ms", (time.time() - t0) * 1000),
            command=cmd,
            stderr_tail=stderr_tail,
        )


def _tail(text: str | None, n: int = 2000) -> str:
    return (text or "")[-n:]


def _dominant_model(wrapper: dict) -> str | None:
    """The wrapper has no top-level "model" field -- confirmed against a real run 2026-09-04,
    it only carries a per-model `modelUsage` breakdown (the main investigation model plus any
    small internal helper calls). Pick the one that was actually billed the most."""
    usage = wrapper.get("modelUsage")
    if not isinstance(usage, dict) or not usage:
        return None
    return max(usage, key=lambda model_id: usage[model_id].get("costUSD", 0) or 0)
