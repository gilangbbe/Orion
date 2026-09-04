# 08 — Development Phases

The project starts from a clean slate. Do not implement the complete application immediately.

## Phase 0 — Technology feasibility

Objectives:
- evaluate MLX candidate models;
- establish Claude Code as a high-capability reference;
- benchmark code understanding;
- test context strategies;
- identify queries that require deep reasoning;
- evaluate local latency and memory.

Output:
- model-selection report;
- benchmark;
- initial routing hypothesis.

## Phase 1 — Deterministic code intelligence

Build:
```text
Repository
 ↓
AST
 ↓
Symbols
 ↓
References
 ↓
Dependencies
 ↓
Call graph
 ↓
Code Graph
```

No sophisticated agent required.

## Phase 2 — Semantic analysis prototype

Build:
```text
Code Graph
 ↓
Claude Code
 ↓
Semantic Components
 ↓
Codebase Model
```

Goal:
Determine whether structured semantic knowledge can be reliably reconstructed.

## Phase 3 — MLX Agent

Build:
- intent classification;
- depth routing;
- local model execution;
- deterministic tool use;
- Claude delegation;
- state management.

## Phase 4 — Architecture UI

Build:
- architecture overview;
- component cards;
- relationship visualization;
- evidence view;
- confidence and uncertainty.

## Phase 5 — Adaptive exploration

Implement:
```text
Simple → MLX
Investigative → MLX + tools
Complex → Claude Code
```

Benchmark routing quality and latency.

## Phase 6 — Continuous model updates

Implement:
- evidence-linked updates;
- model revisions;
- contradiction handling;
- uncertainty tracking.

## Phase 7 — Teaching mode

Implement:
- explanation;
- questioning;
- developer answer evaluation;
- misconception detection;
- transfer problems.

## Phase 8 — Product evaluation

Evaluate:
- correctness;
- grounding;
- latency;
- user trust;
- architecture comprehension;
- learning/transfer outcomes.

Only after these phases should the architecture be optimized for production scale.
