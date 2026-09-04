# 02 — System Architecture

## 1. High-level architecture

```text
┌─────────────────────────────────────────────────────────┐
│                       DEVELOPER                         │
└───────────────────────────┬─────────────────────────────┘
                            │
                     GitHub URL / Query
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                  APPLICATION LAYER                      │
│  Repository View │ Architecture │ Explorer │ Teacher   │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                    MLX AGENT LAYER                      │
│  Intent │ Depth │ Planning │ Tools │ Routing │ State   │
│  Claude delegation │ Verification                       │
└───────┬─────────────────────┬───────────────────────────┘
        │                     │
        ▼                     ▼
┌───────────────┐      ┌────────────────────┐
│ Local MLX     │      │ Claude Code        │
│ Model         │      │ Deep Reasoning     │
└───────┬───────┘      └─────────┬──────────┘
        │                        │
        └───────────┬────────────┘
                    ▼
┌─────────────────────────────────────────────────────────┐
│                  KNOWLEDGE LAYER                        │
│ Code Graph │ Components │ Relationships │ Claims       │
│ Evidence │ Confidence │ Uncertainty │ Learning State  │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                 DETERMINISTIC LAYER                    │
│ AST │ Symbols │ References │ Dependencies │ Tests       │
└─────────────────────────────────────────────────────────┘
```

## 2. Responsibilities

| System | Responsibility |
|---|---|
| Repository Ingestion | Clone/download and normalize repository |
| Static Code Intelligence | Extract objective code facts |
| Depth Model | Estimate required analysis/query depth |
| MLX Agent | Orchestrate, route, plan, maintain state |
| Local MLX Model | Handle simple/local reasoning |
| Claude Code | Perform delegated deep investigation |
| Codebase Model | Persist structured understanding |
| Retrieval | Select relevant evidence |
| Verification | Check claims against source |
| Teaching Engine | Test developer understanding |
| UI | Present knowledge, evidence, and uncertainty |

## 3. Architectural rule

Claude Code is a delegated capability, not the system's primary orchestrator.

The MLX agent owns:
- user interaction;
- query classification;
- routing;
- tool selection;
- Claude delegation;
- state management;
- result ingestion;
- verification;
- final response construction.

## 4. Data flow

```text
Repository
  ↓
Deterministic analysis
  ↓
Code Graph
  ↓
Semantic analysis
  ↓
Codebase Model
  ↓
Architecture UI
  ↓
User query
  ↓
Depth Model
  ↓
MLX or Claude Code
  ↓
Evidence verification
  ↓
Codebase Model update
  ↓
User response
```
