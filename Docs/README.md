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

Phases 0-4.5 complete (MLX model feasibility, deterministic code intelligence, semantic analysis
prototype, MLX agent, architecture UI, UI/UX redesign). Phase 5 (adaptive exploration:
guardrails, conversational sessions, routing benchmark, session rename & delete) is complete,
M0-M8.5. Phase 6 (continuous, evidence-linked model revisions) is complete, M0-M6. Phase 7
(teaching mode) is planned only — see `17_phase7_teaching_mode.md`. No production/shipping
implementation is assumed at this stage.

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
- `12_phase3_mlx_agent.md` — Phase 3 plan (complete)
- `13_phase4_architecture_ui.md` — Phase 4 plan (complete)
- `14_phase4_5_ui_ux_redesign.md` — Phase 4.5 plan (complete)
- `15_phase5_adaptive_exploration.md` — Phase 5 plan (complete, M0-M8.5)
- `16_phase6_continuous_model_updates.md` — Phase 6 plan (complete, M0-M6)
- `17_phase7_teaching_mode.md` — Phase 7 plan (teaching mode; plan only, not started)
- `18_os27_foundation_models_coreai.md` — OS 27 Foundation Models + Core AI backend
- `19_ios_companion.md` — iOS companion app (explore + learn on iPhone via on-device Foundation Models; M0–M8 done)
- `20_mac_redesign.md` — Mac app redesign with the Apple HIG and SwiftUI Pro (R1–R7 done)
