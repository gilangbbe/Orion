"""Phase 2 — Claude Code CLI bridge (Docs/11_phase2_semantic_analysis.md, M1).

Stands in for the "MLX Agent invokes Claude Code" step of Docs/06_claude_code_integration.md
until Phase 3's agent exists: `investigate.py` shells out to the `claude` CLI in headless mode
to produce a candidate `semantic_findings.json`; `schema.py` is the Python-side (step 1, coarse)
half of the Docs/11 validation pipeline whose full version (steps 1-5) lives in Swift
(`OrionCodeIntel/Semantic/SemanticImporter.swift`) and is the actual authority.
"""
