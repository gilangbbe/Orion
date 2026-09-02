"""Grading: deterministic axes always; subjective axes via a pluggable LLM judge.

The 7 Task 3 axes (0-2 each unless noted):
  correctness              judge  (fallback heuristic)
  completeness             judge  (fallback: required-concept keyword coverage)
  architectural_reasoning  judge  (fallback: None -> excluded from composite)
  hallucination            judge + deterministic fabricated-path check (0 = bad, 2 = clean)
  evidence_accuracy        deterministic (citation overlap vs gold, fabrication penalty)
  structured_output        deterministic (JSON recovered? schema-valid?)
  teaching_quality         judge, TE/TR items only; None elsewhere

Also recorded (not composite axes): epistemic_alignment vs expected_epistemic_status.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Callable

_WORD = re.compile(r"[a-z0-9_]+")
_STOP = {
    "the", "a", "an", "of", "to", "in", "is", "it", "and", "or", "for", "on", "with", "that",
    "this", "as", "by", "be", "are", "not", "no", "so", "if", "at", "from", "via", "its",
    "when", "what", "which", "does", "do", "how", "then", "than", "into", "up", "out",
}


def _tokens(s: str) -> set[str]:
    return {w for w in _WORD.findall((s or "").lower()) if w not in _STOP and len(w) > 2}


def _repo_paths(repo_root: str | Path) -> set[str]:
    root = Path(repo_root)
    out: set[str] = set()
    for p in root.rglob("*"):
        if p.is_file():
            out.add(str(p.relative_to(root)))
    return out


# ---------------------------------------------------------------- deterministic

def score_structured_output(json_method: str, schema_valid: bool) -> int:
    if schema_valid:
        return 2
    if json_method in ("clean", "fenced", "braces"):
        return 1
    return 0


def score_evidence(answer_obj: dict | None, question: dict, repo_paths: set[str]) -> dict:
    gold_files = {f for f in question.get("relevant_files", [])}
    gold_syms = {s.split("::")[-1].split(".")[-1].lower()
                 for s in question.get("relevant_symbols", [])}
    cited_files, cited_syms, fabricated = [], [], []
    for e in (answer_obj or {}).get("evidence", []) or []:
        if not isinstance(e, dict):
            continue
        f = str(e.get("file", "")).strip()
        if f:
            cited_files.append(f)
            # fabricated = looks like a repo path but does not exist
            base = f.split(":")[0].lstrip("./")
            if (base.endswith(".py") or base.endswith(".md")) and base not in repo_paths \
                    and not any(base == rp or rp.endswith("/" + base) for rp in repo_paths):
                fabricated.append(f)
        sym = e.get("symbol")
        if isinstance(sym, str) and sym.strip():
            cited_syms.append(sym.split("::")[-1].split(".")[-1].lower())

    def _norm(x: str) -> str:
        return x.split(":")[0].lstrip("./")

    cited_norm = {_norm(c) for c in cited_files}
    gold_norm = {_norm(g) for g in gold_files}
    file_recall = len(cited_norm & gold_norm) / len(gold_norm) if gold_norm else 0.0
    sym_recall = len(set(cited_syms) & gold_syms) / len(gold_syms) if gold_syms else 0.0
    hit = max(file_recall, sym_recall)

    if fabricated:
        score = 0
    elif hit >= 0.5:
        score = 2
    elif hit > 0 or (cited_norm & gold_norm):
        score = 1
    else:
        score = 0
    return {
        "evidence_accuracy": score,
        "evidence_file_recall": round(file_recall, 3),
        "evidence_symbol_recall": round(sym_recall, 3),
        "fabricated_paths": fabricated,
        "n_citations": len(cited_files),
    }


def score_completeness_proxy(answer_obj: dict | None, question: dict) -> dict:
    text = ""
    if answer_obj:
        text = str(answer_obj.get("answer", "")) + " " + " ".join(
            str(x) for x in (answer_obj.get("key_points") or [])
        )
    hay = _tokens(text)
    concepts = question.get("required_concepts", [])
    if not concepts:
        return {"completeness_proxy": None, "concept_coverage": None}
    covered = 0
    for c in concepts:
        ct = _tokens(c)
        if not ct:
            continue
        # concept counts as covered if >=60% of its salient tokens appear
        if len(ct & hay) / len(ct) >= 0.6:
            covered += 1
    frac = covered / len(concepts)
    proxy = 2 if frac >= 0.75 else 1 if frac >= 0.35 else 0
    return {"completeness_proxy": proxy, "concept_coverage": round(frac, 3)}


def score_epistemic(answer_obj: dict | None, question: dict) -> dict:
    exp = question.get("expected_epistemic_status")
    got = (answer_obj or {}).get("epistemic_status")
    if not exp:
        return {"epistemic_alignment": None, "epistemic_expected": None, "epistemic_got": got}
    if got == exp:
        val = 2
    elif {got, exp} <= {"INFERRED", "UNKNOWN"}:
        val = 1
    else:
        val = 0
    return {"epistemic_alignment": val, "epistemic_expected": exp, "epistemic_got": got}


# ---------------------------------------------------------------- LLM judge

JUDGE_SYSTEM = (
    "You are a strict grader for a codebase-comprehension benchmark. You are given a question, "
    "a reference answer with required concepts and common misconceptions, and a candidate "
    "answer. Score the candidate on a 0-2 integer scale per axis:\n"
    "  correctness: 0 wrong/contradicts reference, 1 partially right with a key error, 2 matches "
    "the reference's substance.\n"
    "  completeness: 0 misses most required concepts, 1 covers some, 2 covers all.\n"
    "  architectural_reasoning: 0 just restates the question, 1 names parts but weak on their "
    "interaction, 2 correct mechanism AND interaction.\n"
    "  hallucination: 2 = no invented files/symbols/behaviour and does not assert a listed "
    "misconception; 1 = one minor unsupported claim; 0 = invents things or confidently asserts "
    "a misconception.\n"
    "  teaching_quality: (only if asked) 0 rubber-stamps or misleads, 1 identifies the issue "
    "weakly, 2 identifies it precisely, corrects it, and offers a check.\n"
    "Reward a candidate that correctly says the material is insufficient when the reference "
    "status is UNKNOWN. Respond with ONLY a JSON object: "
    '{"correctness":int,"completeness":int,"architectural_reasoning":int,"hallucination":int,'
    '"teaching_quality":int|null,"rationale":"<=40 words"}'
)


def _judge_user(question: dict, answer_obj: dict | None, raw_text: str) -> str:
    cand = json.dumps(answer_obj, indent=2) if answer_obj else raw_text[:4000]
    parts = [
        f"CATEGORY: {question['category']}",
        f"QUESTION: {question['question']}",
    ]
    if question.get("developer_explanation"):
        parts.append(f"DEVELOPER EXPLANATION UNDER TEST: {question['developer_explanation']}")
    parts += [
        f"REFERENCE ANSWER: {question['expected_answer']}",
        f"REQUIRED CONCEPTS: {json.dumps(question.get('required_concepts', []))}",
        f"COMMON MISCONCEPTIONS (penalise if asserted): "
        f"{json.dumps(question.get('common_misconceptions', []))}",
        f"EXPECTED EPISTEMIC STATUS: {question.get('expected_epistemic_status')}",
        "",
        f"CANDIDATE ANSWER:\n{cand}",
        "",
        "Score now. JSON only.",
    ]
    return "\n".join(parts)


JudgeFn = Callable[[str, str], str]  # (system, user) -> raw completion


def make_mlx_judge(hf_repo: str, max_tokens: int = 500) -> JudgeFn:
    from .runner import ModelRunner
    r = ModelRunner(hf_repo, temperature=0.0, max_gen_tokens=max_tokens)
    r.load()

    def _call(system: str, user: str) -> str:
        return r.generate(
            [{"role": "system", "content": system}, {"role": "user", "content": user}],
            max_gen_tokens=max_tokens,
        ).text

    _call.close = r.unload  # type: ignore[attr-defined]
    return _call


def make_anthropic_judge(model: str = "claude-sonnet-5") -> JudgeFn:
    import os
    import anthropic  # type: ignore

    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

    def _call(system: str, user: str) -> str:
        msg = client.messages.create(
            model=model, max_tokens=600, system=system,
            messages=[{"role": "user", "content": user}],
        )
        return "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")

    return _call


def resolve_judge(spec: str) -> JudgeFn | None:
    if not spec or spec == "none":
        return None
    if spec.startswith("mlx:"):
        return make_mlx_judge(spec[4:])
    if spec == "anthropic" or spec.startswith("anthropic:"):
        model = spec.split(":", 1)[1] if ":" in spec else "claude-sonnet-5"
        return make_anthropic_judge(model)
    raise ValueError(f"unknown judge spec: {spec!r}")


def run_judge(judge: JudgeFn, question: dict, answer_obj: dict | None, raw_text: str) -> dict:
    from .schema import extract_json
    raw = judge(JUDGE_SYSTEM, _judge_user(question, answer_obj, raw_text))
    obj, _ = extract_json(raw)
    if not isinstance(obj, dict):
        return {"judge_ok": False, "judge_raw": raw[:800]}
    out = {"judge_ok": True, "judge_rationale": str(obj.get("rationale", ""))[:400]}
    for k in ("correctness", "completeness", "architectural_reasoning", "hallucination",
              "teaching_quality"):
        v = obj.get(k)
        out[k] = int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    return out


# ---------------------------------------------------------------- top level

COMPOSITE_AXES = ["correctness", "completeness", "architectural_reasoning",
                  "hallucination", "evidence_accuracy", "structured_output"]


def grade_record(rec: dict, question: dict, repo_paths: set[str],
                 judge: JudgeFn | None) -> dict:
    """rec is one line of answers.jsonl (see runner/cli). Returns the grade dict."""
    answer_obj = rec.get("answer_obj")
    raw_text = rec.get("raw_text", "")
    json_method = rec.get("json_method", "none")
    schema_valid = bool(rec.get("schema_valid", False))

    g: dict[str, Any] = {"id": question["id"], "category": question["category"],
                         "difficulty": question["difficulty"]}
    g["structured_output"] = score_structured_output(json_method, schema_valid)
    g.update(score_evidence(answer_obj, question, repo_paths))
    g.update(score_completeness_proxy(answer_obj, question))
    g.update(score_epistemic(answer_obj, question))

    if judge is not None:
        try:
            jr = run_judge(judge, question, answer_obj, raw_text)
        except Exception as exc:  # keep the pipeline alive
            jr = {"judge_ok": False, "judge_error": repr(exc)[:300]}
        g.update(jr)
    else:
        g["judge_ok"] = False

    # fallbacks when no judge score is available
    if g.get("correctness") is None:
        cp, ea = g.get("completeness_proxy"), g.get("epistemic_alignment")
        g["correctness"] = None if cp is None else round((cp + (ea if ea is not None else cp)) / 2)
        g["correctness_is_fallback"] = True
    if g.get("completeness") is None:
        g["completeness"] = g.get("completeness_proxy")
        g["completeness_is_fallback"] = True
    if g.get("hallucination") is None:
        g["hallucination"] = 0 if g.get("fabricated_paths") else 2
        g["hallucination_is_fallback"] = True
    # architectural_reasoning / teaching_quality stay None without a judge

    present = [g[a] for a in COMPOSITE_AXES if isinstance(g.get(a), (int, float))]
    g["composite"] = round(sum(present) / (2 * len(present)), 4) if present else None
    g["composite_axes_used"] = [a for a in COMPOSITE_AXES if isinstance(g.get(a), (int, float))]
    if isinstance(g.get("teaching_quality"), (int, float)):
        g["composite_with_teaching"] = round(
            (sum(present) + g["teaching_quality"]) / (2 * (len(present) + 1)), 4
        )
    return g
