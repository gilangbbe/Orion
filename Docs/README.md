# Orion: Hybrid Agentic Codebase Understanding & Learning System

## Purpose

A local-first macOS developer utility that helps engineers reconstruct, verify, explore, and learn the knowledge embedded in complex codebases.

The system accepts a GitHub repository, constructs a persistent Codebase Mental Model, presents an architectural overview, supports interactive exploration, and provides a teaching mode.

## Core architecture

The local MLX agent owns the product loop and acts as the supervisor/router.

- Deterministic code intelligence establishes structural facts.
- The Codebase Model stores structured knowledge, evidence, confidence, and uncertainty.
- The local MLX model handles simple exploration and reasoning.
- A depth/complexity model determines the required analysis depth.
- Claude Code is delegated to for complex investigations.
- The MLX agent is responsible for interacting with Claude Code and ingesting/validating its results.
- The teaching layer uses the Codebase Model to actively test developer understanding.

## Core principle

> Deterministic analysis establishes facts; the Codebase Model organizes knowledge; MLX provides local orchestration and inexpensive reasoning; Claude Code provides selectively delegated deep reasoning; retrieval supplies evidence; teaching turns the knowledge model into active learning.

## Project status

Phases 0-2 complete (MLX model feasibility, deterministic code intelligence, semantic analysis
prototype). Phase 3 (MLX Agent) is planned, not started. No production/shipping implementation
is assumed at this stage.

See:
- `01_product_specification.md`
- `02_system_architecture.md`
- `03_agent_and_model_routing.md`
- `04_codebase_mental_model.md`
- `05_user_flow_and_ux.md`
- `06_claude_code_integration.md`
- `07_data_models.md`
- `08_development_phases.md`
- `09_research_hypotheses.md`
- `10_phase1_deterministic_code_intelligence.md` — Phase 1 plan (complete)
- `11_phase2_semantic_analysis.md` — Phase 2 plan (complete)
- `12_phase3_mlx_agent.md` — Phase 3 plan (not started)
