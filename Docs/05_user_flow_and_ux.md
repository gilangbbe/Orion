# 05 — User Flow & UX Specification

## 1. Stage 1 — Repository ingestion

User provides a GitHub URL.

System shows:
- repository identity;
- detected languages;
- file/module count;
- analysis progress;
- readiness status.

Do not expose internal agent loops.

## 2. Stage 2 — Analysis

The system:
1. extracts structural facts;
2. identifies candidate modules/components;
3. performs semantic grouping;
4. builds relationships;
5. creates the initial Codebase Model.

The UI may show meaningful progress such as:
- Mapping repository structure
- Identifying components
- Verifying dependencies
- Building architecture

## 3. Stage 3 — Architectural overview

Show:
- major components;
- relationships;
- data flow;
- architectural layers;
- confidence;
- important uncertainties.

Each node should be interactive.

## 4. Stage 4 — Component exploration

Example:

```text
Authentication

Purpose
Coordinates authentication and session management.

Components
AuthService
TokenManager
SessionManager

Dependencies
UserRepository
NetworkClient

Evidence
AuthService.swift:42–80

Confidence
High
```

The developer can ask questions about the selected component.

## 5. Stage 5 — Adaptive exploration

Simple question:

```text
User → MLX Agent → MLX → answer
```

Complex question:

```text
User → MLX Agent → Depth Model
                   ↓
                Claude Code
                   ↓
                findings
                   ↓
             MLX verification
                   ↓
                answer
```

The user should not need to understand the routing mechanism.

## 6. Stage 6 — Continuous model update

When investigation reveals new information, show a concise model-change explanation:

```text
Understanding updated

Previously:
AuthService → Persistence

Now:
AuthService → SessionManager → SessionStore → Keychain

Reason:
New source evidence identified an intermediate session layer.
```

## 7. Stage 7 — Teaching mode

Teaching is active rather than explanation-only.

```text
Explain
  ↓
Question
  ↓
Developer answer
  ↓
Evaluation
  ↓
Correction
  ↓
Transfer problem
```

Example:

> Explain the difference between `TokenManager` and `SessionManager`.

The system evaluates conceptual understanding, not wording similarity.

## 8. Technology visibility

### Visible

- evidence;
- source locations;
- confidence;
- uncertainty;
- model changes;
- relevant architecture;
- whether an answer is verified.

### Hidden by default

- prompts;
- token counts;
- internal tool traces;
- model routing logic;
- Claude invocation details;
- internal state machine.

Principle:

> Expose epistemic transparency, hide computational complexity.

An advanced diagnostic view may later expose deeper traces for expert users.
