"""Prompt construction for the baseline. One system prompt, one user prompt, JSON out."""
from __future__ import annotations

from .schema import SCHEMA_HINT

SYSTEM = (
    "You are a software-comprehension assistant. You will be given the SOURCE, TEST, and DOC "
    "files from the Starlette codebase that are relevant to one question, plus the question.\n"
    "\n"
    "Rules:\n"
    "1. Answer ONLY from the provided material. Do not rely on memory of Starlette.\n"
    "2. Never invent a file path, symbol, function, or behaviour that is not in the material.\n"
    "3. If the material is insufficient to answer, say so plainly and use epistemic_status "
    "UNKNOWN. That is a correct, valued outcome — do not guess.\n"
    "4. Cite specific files and symbols for every substantive claim.\n"
    "5. epistemic_status meaning: VERIFIED = directly shown by the provided code/tests; "
    "INFERRED = a sound deduction not shown line-for-line; UNKNOWN = not answerable from the "
    "material; CONTRADICTED = the provided sources disagree with each other.\n"
    "\n"
    "Respond with a SINGLE JSON object and nothing else, matching this shape:\n"
    f"{SCHEMA_HINT}\n"
)

_CATEGORY_LABEL = {
    "code_understanding": "Code understanding",
    "cross_file_reasoning": "Cross-file reasoning",
    "architecture": "Architecture",
    "dependency_change_impact": "Dependency / change impact",
    "behavioral_reasoning": "Behavioural reasoning",
    "contradiction_detection": "Contradiction detection (docs vs implementation)",
    "evidence": "Evidence identification",
    "teaching": "Teaching — assess the developer's explanation",
    "transfer": "Transfer — reason about a novel scenario",
}


def build_user_prompt(question: dict, context_text: str, commit_sha: str) -> str:
    lines = [
        f"Starlette is pinned at commit {commit_sha}.",
        "",
        "===== BEGIN PROVIDED MATERIAL =====",
        context_text.rstrip(),
        "===== END PROVIDED MATERIAL =====",
        "",
        f"QUESTION CATEGORY: {_CATEGORY_LABEL.get(question['category'], question['category'])}",
        "",
        "QUESTION:",
        question["question"].strip(),
    ]
    if question.get("developer_explanation"):
        lines += [
            "",
            "DEVELOPER'S EXPLANATION TO ASSESS (state whether it is correct, and correct any "
            "misconception):",
            question["developer_explanation"].strip(),
        ]
    lines += ["", "Return the JSON object now."]
    return "\n".join(lines)


def build_messages(question: dict, context_text: str, commit_sha: str) -> list[dict]:
    return [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": build_user_prompt(question, context_text, commit_sha)},
    ]
