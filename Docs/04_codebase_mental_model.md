# 04 — Codebase Mental Model

## 1. Purpose

The Codebase Mental Model is the central persistent representation of the system's current understanding of a repository.

It should be more than a graph of files. It represents:
- structure;
- semantics;
- relationships;
- evidence;
- confidence;
- uncertainty;
- contradictions;
- investigation history.

## 2. Knowledge layers

### Structural knowledge

```text
Files
Modules
Symbols
Functions
Classes
Interfaces
Dependencies
Call relationships
Tests
```

### Semantic knowledge

```text
Components
Responsibilities
Architectural roles
Behaviors
Data flows
Subsystems
```

### Epistemic knowledge

```text
Claims
Evidence
Confidence
Uncertainty
Contradictions
Source
Provenance
```

## 3. Fact versus interpretation

Every knowledge item should be classified where possible as:

- `FACT` — directly established from code/tool output.
- `INTERPRETATION` — semantic interpretation by an LLM.
- `INFERENCE` — conclusion derived from multiple facts.
- `UNKNOWN` — insufficient evidence.
- `CONTRADICTED` — conflicting evidence exists.

The UI must not present inference as fact.

## 4. Example

```text
Authentication
├── AuthService
├── TokenManager
└── SessionManager

Relationships
├── AuthService → TokenManager
├── AuthService → SessionManager
└── AuthService → UserRepository

Claims
└── AuthService coordinates authentication

Evidence
├── AuthService.swift:42–80
└── LoginController.swift:31–52

Confidence
└── high
```

## 5. Model evolution

The model is continuously updated.

```text
Initial model
    ↓
User question
    ↓
Investigation
    ↓
New evidence
    ↓
Model revision
    ↓
Versioned knowledge state
```

Every meaningful update should retain:
- previous state;
- new claim;
- evidence;
- source of update;
- confidence;
- timestamp/version.

## 6. Codebase Model is the source of application knowledge

Chat history should not be the primary source of truth.

The Codebase Model should be queryable independently of any individual conversation.
