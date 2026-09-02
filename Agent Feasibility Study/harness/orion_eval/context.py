"""Controlled-context builder for the Task 3 baseline.

Design constraints:
  * Model-independent. The context bytes are identical for every model so scores are
    comparable. Budgeting is by CHARACTER count, not tokens (no tokenizer in the loop).
  * Deterministic. Files are included in the order the benchmark lists them.
  * Honest about truncation. If the relevant files exceed the budget, the largest files
    are head/tail-truncated and `truncated=True` is recorded.
  * This is Task 4's "Condition A / Direct" context (question + relevant source). Tasks 4-6
    introduce RAG / structured-graph / tool variants on top of the same benchmark.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

CHAR_BUDGET = 110_000          # ~27-28K tokens; every seed/short-list model supports >=32K
PER_FILE_MIN_KEEP = 2_000      # never truncate a file below this many chars
HEAD_FRAC = 0.6                # when truncating, keep 60% head / 40% tail


@dataclass
class BuiltContext:
    text: str
    files_included: list[str] = field(default_factory=list)
    files_missing: list[str] = field(default_factory=list)
    total_chars: int = 0
    approx_tokens: int = 0
    truncated: bool = False
    truncated_files: list[str] = field(default_factory=list)


def _read(repo_root: Path, rel: str) -> str | None:
    p = repo_root / rel
    if not p.is_file():
        return None
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return None


def _truncate(body: str, keep: int) -> str:
    if len(body) <= keep:
        return body
    head = int(keep * HEAD_FRAC)
    tail = keep - head
    removed = len(body) - keep
    return (
        body[:head]
        + f"\n\n... [TRUNCATED {removed} chars for context budget] ...\n\n"
        + body[len(body) - tail :]
    )


def build_context(relevant_files: list[str], repo_root: str | os.PathLike,
                  char_budget: int = CHAR_BUDGET) -> BuiltContext:
    root = Path(repo_root)
    raw: list[tuple[str, str]] = []
    ctx = BuiltContext(text="")

    for rel in relevant_files:
        body = _read(root, rel)
        if body is None:
            ctx.files_missing.append(rel)
            continue
        raw.append((rel, body))
        ctx.files_included.append(rel)

    # Wrapper overhead per file header/footer.
    def wrap(rel: str, body: str) -> str:
        return f"# ===== FILE: {rel} =====\n{body}\n# ===== END {rel} =====\n\n"

    overhead = sum(len(wrap(r, "")) for r, _ in raw)
    content_budget = max(char_budget - overhead, 0)
    total_content = sum(len(b) for _, b in raw)

    if total_content <= content_budget or not raw:
        parts = [wrap(r, b) for r, b in raw]
    else:
        # Proportionally shrink the biggest files first, respecting PER_FILE_MIN_KEEP.
        keeps = {r: len(b) for r, b in raw}
        order = sorted(raw, key=lambda t: len(t[1]), reverse=True)
        need_to_cut = total_content - content_budget
        for r, b in order:
            if need_to_cut <= 0:
                break
            cuttable = max(len(b) - PER_FILE_MIN_KEEP, 0)
            cut = min(cuttable, need_to_cut)
            keeps[r] = len(b) - cut
            need_to_cut -= cut
        parts = []
        for r, b in raw:
            k = keeps[r]
            if k < len(b):
                ctx.truncated = True
                ctx.truncated_files.append(r)
                parts.append(wrap(r, _truncate(b, k)))
            else:
                parts.append(wrap(r, b))

    ctx.text = "".join(parts)
    ctx.total_chars = len(ctx.text)
    ctx.approx_tokens = ctx.total_chars // 4
    return ctx
