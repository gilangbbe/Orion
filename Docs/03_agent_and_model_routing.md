# 03 — Agent, Depth Model & Model Routing

## 1. MLX Agent

The MLX agent is the supervisory intelligence of the application.

It should:
1. interpret user intent;
2. inspect current Codebase Model state;
3. determine required depth;
4. select tools/context;
5. choose local MLX or Claude Code;
6. ingest results;
7. verify evidence;
8. update state;
9. produce the user-facing response.

## 2. Depth model

The depth model determines how much investigation a query requires. It does not answer the query.

```text
Query
  ↓
Depth Model
  ├── Level 1: Simple → MLX
  ├── Level 2: Investigative → MLX + deterministic tools
  └── Level 3: Complex → Claude Code
```

### Level 1 examples

- What does `AuthService` do?
- Which files belong to this component?
- What is the responsibility of this class?

Execution:
`MLX + Codebase Model`

### Level 2 examples

- Which components depend on `AuthService`?
- Where is this data persisted?
- What tests cover this component?

Execution:
`MLX + deterministic tools + retrieval`

### Level 3 examples

- Why was the authentication architecture designed this way?
- What would happen if the authentication provider were replaced?
- Explain the emergent behavior across several subsystems.

Execution:
`MLX Agent → Claude Code → verification`

## 3. Initial routing policy

Start with explicit rules rather than a fully autonomous router.

```text
if query is simple:
    use MLX

if query requires deterministic facts:
    use MLX + tools

if query requires cross-component investigation:
    use MLX + tools

if ambiguity remains:
    escalate to Claude Code

if architectural reasoning is deep:
    escalate to Claude Code

if local model confidence is low:
    escalate to Claude Code
```

## 4. Adaptive-compute principle

```text
                    QUERY
                      │
                      ▼
                 Depth Model
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
      SIMPLE       INVESTIGATE     COMPLEX
        │             │             │
        ▼             ▼             ▼
       MLX       MLX + tools      Claude
                                     │
                                     ▼
                              MLX verification
```

The goal is not to maximize agentic reasoning. The goal is to use the minimum computation needed to achieve reliable understanding.

## 5. Claude result handling

Never pipe Claude output directly to the user or blindly write it into the model.

Required path:

```text
Claude result
  ↓
Schema validation
  ↓
Evidence validation
  ↓
Consistency check
  ↓
Codebase Model update
  ↓
User response
```
