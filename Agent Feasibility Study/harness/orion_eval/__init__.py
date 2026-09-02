"""Orion / Codebase Mentor — Task 3 baseline-evaluation harness.

Pipeline: resolve-anchors -> run -> grade -> leaderboard.
No RAG, no agents (that is Tasks 4 and 6). Each model gets a fixed, model-independent
"controlled context": the verbatim source/test/doc files the benchmark marks as relevant,
truncated only by a character budget so every model sees the exact same bytes.
"""

__version__ = "0.1.0"
EXPERIMENT_NAME = "orion-task3-baseline"
