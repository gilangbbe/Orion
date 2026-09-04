# 06 — Claude Code Integration

## 1. Purpose

Claude Code is the high-capability reasoning backend used selectively for complex analysis.

It is not the primary product orchestrator.

The local MLX agent owns the interaction with Claude Code.

## 2. Conceptual flow

```text
User Query
    ↓
MLX Agent
    ↓
Depth Model
    ↓
Complexity = HIGH
    ↓
Prepare investigation context
    ↓
Invoke Claude Code
    ↓
Claude investigates repository
    ↓
Structured findings
    ↓
MLX Agent
    ↓
Evidence verification
    ↓
Codebase Model update
    ↓
User explanation
```

## 3. Delegated tasks

Claude Code may be used for:
- deep semantic grouping;
- ambiguous architectural interpretation;
- multi-subsystem reasoning;
- complex dependency investigation;
- change-impact reasoning;
- behavioral reasoning across files;
- resolving uncertainty that local MLX cannot reliably resolve.

## 4. Structured output contract

Claude should return structured knowledge rather than arbitrary prose.

Example:

```json
{
  "components": [
    {
      "name": "Authentication",
      "responsibility": "Coordinates user authentication",
      "members": [
        "AuthService",
        "TokenManager",
        "SessionManager"
      ]
    }
  ],
  "relationships": [
    {
      "source": "AuthService",
      "target": "TokenManager",
      "type": "depends_on"
    }
  ],
  "claims": [
    {
      "statement": "AuthService validates authentication state",
      "evidence": [
        "AuthService.swift:42-58"
      ],
      "confidence": "high"
    }
  ],
  "uncertainties": []
}
```

The exact schema should be versioned.

## 5. Claude Code as an experimental capability

During R&D, Claude Code can establish a high-capability reference point.

The architecture should keep the model-provider boundary explicit:

```text
Semantic Analysis Interface
       ├── Local MLX
       ├── Claude Code
       └── Future provider
```

This prevents the system from becoming permanently coupled to Claude.

## 6. Usage constraints

The implementation must use supported Claude Code/subscription mechanisms and respect account limits and product terms.

Do not implement UI scraping, credential extraction, or mechanisms intended to bypass usage controls.

## 7. Failure behavior

If Claude:
- returns invalid structure;
- cannot find evidence;
- produces contradictory claims;
- exceeds the investigation budget;

the MLX agent should mark the result as unverified or incomplete rather than presenting it as truth.
