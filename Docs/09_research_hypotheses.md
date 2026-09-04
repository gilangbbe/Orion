# 09 — Research Hypotheses & Evaluation

The architecture is a hypothesis and must be empirically validated.

## H1 — Deterministic structure

A deterministic code graph improves LLM codebase understanding compared with raw source alone.

## H2 — Persistent model

A persistent Codebase Mental Model improves consistency across repeated developer queries.

## H3 — Local sufficiency

Most routine codebase exploration questions can be answered adequately by a local MLX model.

## H4 — Selective escalation

A smaller subset of complex questions benefits substantially from Claude-level reasoning.

## H5 — Routing

The MLX agent and depth model can identify when Claude-level reasoning is necessary.

## H6 — Delegated reasoning

Claude findings can be ingested and verified by the MLX agent without making Claude the permanent system orchestrator.

## H7 — Epistemic transparency

Evidence, confidence, uncertainty, and model-change visibility improve trust more effectively than exposing raw agentic traces.

## H8 — Active learning

Interactive teaching produces better developer understanding and transfer than explanation-only interaction.

## Core benchmark dimensions

For model and architecture evaluation:
- correctness;
- completeness;
- architectural reasoning;
- evidence accuracy;
- hallucination rate;
- structured-output reliability;
- latency;
- memory;
- number of tool calls;
- unnecessary tool calls.

For teaching evaluation:
- conceptual understanding;
- misconception detection;
- recall;
- change-impact reasoning;
- novel-scenario transfer.

## Key research question

The most important architectural question is not:

> Can an LLM explain a repository?

It is:

> What combination of deterministic code intelligence, persistent semantic modeling, local reasoning, delegated deep reasoning, and active teaching produces reliable codebase understanding while keeping computation and complexity proportional to the user's actual need?
