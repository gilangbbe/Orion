# Product & Technical Project Specification

# Project: Codebase Mentor

**Working description:**  
**An Agentic Utility App Using Apple’s AI Environment That Reduces Developer Knowledge Debt by Keeping Developers Actively Engaged in the Learning Process**

**Platform:** macOS  
**Primary AI Environment:** Apple Foundation Models / Foundation Models framework  
**Primary repository source:** GitHub  
**Primary user:** Software engineers working with unfamiliar or complex codebases

---

# 1. Executive Summary

## 1.1 Problem

AI-assisted software development has significantly reduced the cost of producing and modifying code. However, this creates a potential knowledge problem:

> Developers can increasingly modify systems that they do not fully understand.

Over time, the gap between:

- what the codebase actually does,
- what the developer believes it does,
- what documentation says it does,
- and what an AI assistant believes it does

can become **developer knowledge debt**.

Traditional AI coding assistants primarily optimize for task completion:

> "Write this code."

> "Fix this bug."

> "Explain this function."

These interactions can provide information without necessarily producing a durable mental model of the system.

## 1.2 Product thesis

Codebase Mentor takes a different approach:

> **The AI should not simply explain the codebase to the developer. It should construct an inspectable model of the codebase, provide evidence for that model, and progressively help the developer build and validate their own mental model.**

The product therefore has two related objectives:

### System objective

Construct an accurate, evidence-backed representation of a complex codebase.

### Human objective

Reduce the divergence between:

> **What the system actually does**

and

> **What the developer understands the system to do.**

---

# 2. Product Vision

## Vision

> **Turn unfamiliar codebases from something developers operate into something developers understand.**

The long-term product should function as an **AI-powered codebase apprenticeship system**.

The developer connects a repository and receives an initial architectural model.

They can then:

1. inspect the architecture,
2. explore individual components,
3. ask contextual questions,
4. inspect the evidence behind AI claims,
5. challenge the model,
6. update their understanding,
7. enter teaching mode,
8. test their understanding,
9. and eventually solve problems independently.

The desired end state is not:

> "The AI knows the repository."

It is:

> **"The developer can reason about the repository without the AI."**

---

# 3. Core Design Principle

## Epistemic visibility over computational visibility

The system should expose:

- what it believes,
- why it believes it,
- what evidence supports it,
- what is uncertain,
- what contradicts it,
- and what changed.

The system should generally hide:

- raw chain-of-thought,
- internal prompts,
- every tool call,
- token-level reasoning,
- agent orchestration details,
- internal retries,
- implementation-specific state.

### Principle

> **Expose the AI's epistemic footprint, not its computational footprint.**

---

# 4. Product Abstraction

The product should not be modeled as:

```text
Six autonomous agents
    ↓
Reconstruct
    ↓
Verify
    ↓
Evaluate
    ↓
Challenge
    ↓
Remember
    ↓
Transfer
```

That architecture is unnecessarily expensive and conflates different abstraction levels.

Instead, the product is built around three fundamental functions:

```text
1. MODEL
   What does this codebase appear to do?

2. EVIDENCE
   What supports or contradicts that model?

3. TEACH
   Does the developer actually understand the model?
```

Supported by:

```text
KNOWLEDGE STATE
Persistent representation of:
- claims
- evidence
- uncertainty
- user understanding
- unresolved questions
```

And evaluated through:

```text
MASTERY ASSESSMENT
Can the developer independently apply the knowledge?
```

---

# 5. Target Users

## Primary persona — Software Engineer

Characteristics:

- joins an unfamiliar project,
- inherits an existing repository,
- uses AI coding tools,
- needs to modify existing systems,
- lacks complete architectural documentation,
- needs to understand dependencies and failure modes.

Typical situations:

### New employee

> "I need to understand this repository before touching production code."

### Existing engineer

> "I've worked on this service for months, but I don't understand this subsystem."

### AI-heavy developer

> "AI generated most of this feature. I need to understand what it actually does."

### Maintainer

> "I need to determine what could break if I change this component."

---

# 6. User Problem Statement

A developer connecting to an unfamiliar repository currently has to reconstruct the mental model manually from:

- source code,
- README files,
- documentation,
- tests,
- Git history,
- dependency relationships,
- configuration,
- production behavior,
- conversations with other engineers.

The process is expensive because knowledge is distributed across artifacts.

The product should reduce the cost of this reconstruction while preserving the developer's active role.

---

# 7. User Flow

## Overview

```text
GitHub Repository
       ↓
Repository Analysis
       ↓
Initial Codebase Model
       ↓
Architectural Overview
       ↓
Interactive Exploration
       ↓
Contextual Questions
       ↓
Model Updates
       ↓
Teaching Mode
       ↓
Challenge / Practice
       ↓
Independent Understanding
```

---

# 8. Stage 1 — Repository Connection

## User action

User provides a GitHub repository.

Possible entry points:

```text
Paste GitHub URL
```

or:

```text
Connect GitHub
→ Select repository
```

The preferred production implementation should use a GitHub App with minimum required permissions.

GitHub Apps allow access to be scoped to selected repositories and require explicit permission grants. GitHub recommends requesting the minimum permissions necessary.

## MVP permission model

Read-only repository access.

Required capabilities:

- repository metadata
- repository contents
- branches/commits

Potential future permissions:

- pull requests
- issues
- Actions
- deployment information

No write access should be required for MVP.

---

# 9. Repository Scope Contract

Before analysis begins, the user should see exactly what will be analyzed.

Example:

```text
Repository
my-org/payment-service

Commit
a81f4c2

Files
184

Languages
Python
TypeScript
SQL

Analyzed
✓ Source code
✓ Tests
✓ Configuration
✓ README
✓ Git metadata

Not analyzed
○ Secrets
○ Binary files
○ Generated files
○ External services
○ Production infrastructure
```

## Purpose

This establishes the boundary of the AI's knowledge.

The system should never imply:

> "I understand the entire system"

when it has only analyzed the repository.

---

# 10. Stage 2 — Repository Analysis

The system creates an initial Codebase Model.

## Deterministic analysis layer

Use traditional software-analysis technologies wherever possible.

Do not ask an LLM to rediscover information available deterministically.

### Extract:

- repository tree
- files
- modules
- packages
- classes
- functions
- imports
- dependencies
- call relationships
- inheritance
- interfaces
- APIs
- database schemas
- configuration
- tests
- environment variables
- entry points
- build system
- dependency manifests

### Technologies

Potential implementation:

- Tree-sitter
- Language Server Protocol
- compiler/parser APIs
- Git
- dependency graph extraction
- static analysis
- language-specific analyzers

---

# 11. Semantic Analysis Layer

The Foundation Model is used where semantic interpretation is necessary.

Examples:

> "What role does this module play?"

> "Why does this service exist?"

> "What business concept does this component represent?"

> "What architectural boundary does this represent?"

Apple's Foundation Models framework supports language understanding, structured generation, and tool calling. It can call application-defined tools to query data and ground responses in application sources of truth.

---

# 12. Codebase Model

The central product artifact is the:

# Codebase Model

It represents the system at multiple abstraction levels.

```text
Repository
    ↓
System
    ↓
Subsystem
    ↓
Component
    ↓
Module
    ↓
File
    ↓
Symbol
    ↓
Function
```

Each object contains:

```text
Identity
Purpose
Relationships
Evidence
Confidence / evidence strength
Known exceptions
Open questions
Last verified commit
```

---

# 13. Knowledge Representation

The model should be represented as a graph.

## Example

```text
PaymentService
    │
    ├── depends_on → PaymentRepository
    │
    ├── depends_on → PaymentProvider
    │
    ├── stores → Payment
    │
    └── called_by → CheckoutService
```

Each edge is a claim.

```text
PaymentService
      │
      └── depends_on
             │
             ▼
      PaymentProvider
```

The edge should contain:

```json
{
  "type": "depends_on",
  "status": "verified",
  "evidence": [
    "payment/service.py:82",
    "payment/provider.py",
    "test_payment.py"
  ],
  "last_verified_commit": "a81f4c2"
}
```

---

# 14. Epistemic Status

Every significant model claim should have an epistemic status.

## Verified

Supported by direct implementation or independent evidence.

```text
✓ VERIFIED
```

## Inferred

Strong interpretation but not directly established.

```text
~ INFERRED
```

## Unknown

Insufficient evidence.

```text
? UNKNOWN
```

## Contradicted

Different evidence conflicts.

```text
⚠ CONTRADICTED
```

This is preferable to a generic numerical confidence score.

---

# 15. Evidence Model

Evidence should be first-class.

Possible evidence sources:

### Source code

```text
payment/service.py:82
```

### Static analysis

```text
PaymentService → PaymentRepository
```

### Tests

```text
test_payment_idempotency.py
```

### Git history

```text
commit a81f4c2
```

### Documentation

```text
README.md
architecture.md
```

### Runtime evidence

Future capability:

```text
trace: checkout → payment → provider
```

---

# 16. Evidence Strength

Instead of:

```text
Confidence: 92%
```

use:

```text
Evidence strength: Strong

✓ Direct implementation
✓ Call graph
✓ Integration tests
✓ Documentation

⚠ No runtime evidence
```

This allows the engineer to independently assess the claim.

---

# 17. Stage 3 — Architectural Overview

The initial experience should present a **compressed architecture**, not literally every component.

## Principle

> Optimize for completeness of the mental model at the current abstraction level, not completeness of information.

Example:

```text
                 APPLICATION

                 API Gateway
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
    Order Service            User Service
          │
          ▼
    Payment Service
          │
          ▼
    Payment Provider
```

The overview should show:

- major components
- important relationships
- primary data flows
- external dependencies
- system boundaries
- critical entry points

---

# 18. Hierarchical Exploration

The architecture should support progressive disclosure.

```text
System
 ↓
Subsystem
 ↓
Component
 ↓
Module
 ↓
File
 ↓
Function
```

Users should not need to understand the entire repository simultaneously.

---

# 19. Component Detail View

Selecting a component opens:

```text
PAYMENT SERVICE

Purpose
Processes payment requests and records payment state.

Depends on
→ Payment Provider
→ PostgreSQL
→ Redis

Used by
← Checkout Service
← Reconciliation Worker

Evidence
12 files
8 call relationships
5 tests

Status
✓ Supported

Open question
Why does reconciliation bypass the standard payment queue?
```

Actions:

```text
[Ask]
[Inspect Evidence]
[View Source]
[View Relationships]
[Challenge Model]
[Teach Me]
```

---

# 20. Technology Visibility During Architecture Exploration

## Visible by default

- architecture
- relationships
- evidence status
- important uncertainties
- source references

## Hidden by default

- tool calls
- model prompts
- internal agent iterations
- retrieval chunks
- token counts

## Available on demand

- analysis methodology
- source tracing
- call graph
- dependency graph
- Git history
- verification results

---

# 21. Stage 4 — Contextual Querying

The user can ask questions about the current component.

Example:

> "Why does PaymentService use Redis?"

The system should answer:

```text
Redis is used as part of payment idempotency.

Evidence:
• payment/idempotency.py
• payment/service.py
• test_payment_idempotency.py

The implementation stores an idempotency key
before allowing the payment operation to proceed.

Model status:
✓ Supported
```

---

# 22. Context Anchoring

Questions should automatically inherit the user's current context.

If the user is inspecting:

```text
PaymentService
    ↓
PaymentRepository
```

then:

> "Why does this use Redis?"

should resolve to the selected component rather than requiring the user to repeat context.

---

# 23. Model Updating

User questions may reveal new knowledge.

The model should update incrementally.

Example:

### Before

```text
PaymentService → Stripe
```

### New evidence

The user discovers:

```text
PaymentRouter
```

### Updated model

```text
PaymentService
      ↓
PaymentRouter
   ↙       ↘
Stripe     Adyen
```

The system should show:

> **Model updated**

and explain:

```text
New evidence:
• payment/router.py
• routing configuration
• 3 call paths

Previous interpretation:
PaymentService directly selected Stripe.

Updated interpretation:
PaymentRouter selects the provider.
```

---

# 24. Knowledge Diff

The product should maintain a history of model changes.

```text
Codebase Model

v1
Initial architecture

v2
Payment routing discovered

v3
Internal reconciliation path discovered
```

Each version contains:

- added claims
- removed claims
- changed relationships
- new evidence
- invalidated evidence
- unresolved questions

This is effectively:

> **Git for the AI's understanding of the codebase.**

---

# 25. Stage 5 — Challenge the Model

The user should be able to explicitly challenge the AI.

Example:

> "I think PaymentService does not directly access the database."

System:

```text
Your claim

PaymentService does not directly access Database.

Current model

PaymentService → Database

Evidence

payment/service.py:82
payment/repository.py:31
```

Actions:

```text
[Inspect Evidence]
[Agree]
[Reject]
[Provide Explanation]
```

If the user is correct:

```text
Model corrected.

Reason:
The previous relationship was inferred incorrectly.
```

If the AI is correct:

```text
Model retained.

The relationship is supported by:
...
```

---

# 26. Stage 6 — Teaching Mode

Teaching mode is deliberately different from normal querying.

## Objective

Move from:

> information retrieval

to:

> knowledge acquisition.

The system should progressively reduce direct explanation and increase active participation.

---

# 27. Teaching Loop

```text
Explain
   ↓
Ask
   ↓
User predicts
   ↓
Evaluate
   ↓
Provide feedback
   ↓
Correct mental model
   ↓
Apply to new situation
```

Example:

> "Before we continue, what do you think happens if payment succeeds but order persistence fails?"

The user answers.

The system evaluates the answer against the Codebase Model and evidence.

---

# 28. Teaching Modes

## Guided

AI explains concepts and asks lightweight questions.

## Socratic

AI primarily asks questions.

## Challenge

User must predict system behavior.

## Debugging

User diagnoses a simulated failure.

## Architecture

User explains relationships between components.

## Change impact

User predicts what will break after a modification.

---

# 29. Knowledge State

The product should maintain a separate representation of:

# User Knowledge Model

Example:

```text
Authentication
    Architecture       92%
    Token lifecycle    78%
    Refresh flow       41%
    Internal auth      27%

Payments
    Architecture       88%
    Idempotency        74%
    Failure handling   52%
```

These numbers should be treated as **assessment indicators**, not objective measures of human intelligence.

Better UI:

```text
Strong understanding
Partial understanding
Needs investigation
Not demonstrated
```

---

# 30. Knowledge Evidence

The system should not claim:

> "You understand authentication 92%."

Instead:

> **Strong understanding demonstrated**

Evidence:

- correctly explained authentication flow
- predicted token expiration behavior
- correctly diagnosed an authentication failure
- successfully traced a request through middleware

This keeps the system epistemically honest.

---

# 31. Transfer / Mastery

Mastery should be measured separately from normal interaction.

The system periodically gives the developer a novel scenario.

Example:

> "A request is reaching the database without authentication. Diagnose where the failure could occur."

The user must solve the problem without immediately receiving the answer.

The system compares the response against:

- Codebase Model
- verified relationships
- known failure modes

---

# 32. AI Independence Metric

One of the most important product metrics:

> **How much can the developer accomplish without AI assistance?**

Track:

```text
Assisted understanding
        ↓
Guided understanding
        ↓
Independent explanation
        ↓
Independent debugging
        ↓
Independent change-impact analysis
```

The product should ideally reduce dependence over time.

---

# 33. Agent Architecture

The system should use **adaptive agentic depth**.

It should not always execute a full reasoning loop.

## Depth 0 — Retrieval

```text
Index → Retrieve → Answer
```

Example:

> "Where is the User class?"

---

## Depth 1 — Explanation

```text
Retrieve → LLM → Explain
```

Example:

> "What does UserService do?"

---

## Depth 2 — Reconstruction

```text
Retrieve
   ↓
Graph traversal
   ↓
LLM synthesis
```

Example:

> "Explain the authentication architecture."

---

## Depth 3 — Verification

```text
Model claim
   ↓
Evidence retrieval
   ↓
Static analysis / tests
   ↓
Verified claim
```

Example:

> "Is authentication guaranteed before database access?"

---

## Depth 4 — Teaching

```text
Codebase Model
   ↓
User Knowledge Model
   ↓
Challenge
   ↓
Assessment
```

---

## Depth 5 — Mastery

```text
Novel scenario
   ↓
Independent user solution
   ↓
Evaluation
```

---

# 34. Depth Router

A central router decides how much computation is necessary.

Inputs:

```text
Question complexity
Repository complexity
Uncertainty
Evidence availability
Potential consequence
User intent
User expertise
Learning mode
```

Output:

```text
Required depth = 0...5
```

Example:

```text
"Where is authentication implemented?"
→ Depth 0

"How does authentication work?"
→ Depth 2

"Can authentication be bypassed?"
→ Depth 3

"Teach me authentication."
→ Depth 4

"Test whether I understand authentication."
→ Depth 5
```

---

# 35. Persistent Knowledge Model

The system should not reconstruct the entire repository for every question.

Persist:

```text
Codebase Model
Knowledge Claims
Evidence
Uncertainty
User Knowledge
Open Questions
Model Versions
```

When code changes, invalidate only affected knowledge.

---

# 36. Incremental Updating

A commit changes:

```text
payment/service.py
```

The system identifies impacted model nodes:

```text
PaymentService
PaymentRepository
CheckoutService
Payment Architecture
```

Only these areas need re-analysis.

This avoids repeatedly paying the cost of full reconstruction.

---

# 37. Apple Foundation Models Architecture

The application should use Apple's Foundation Models framework as the primary on-device intelligence layer.

Apple provides:

- on-device foundation models,
- structured generation,
- tool calling,
- dynamic model/session configuration,
- agentic app support,
- model evaluation facilities.

Apple also notes that the on-device model is suitable for many language-understanding and generation tasks, while larger reasoning/context requirements may require Private Cloud Compute or another provider.

---

# 38. Proposed Apple Technology Stack

## Application

```text
Swift
SwiftUI
macOS
```

## AI

```text
Foundation Models framework
LanguageModelSession
SystemLanguageModel
@Generable
Tool
Dynamic Profiles
```

## System intelligence

```text
Foundation Models
    ↓
Tool Calling
    ↓
Local Codebase Services
```

Apple's `Tool` abstraction is particularly suitable because the model can call application-defined tools to retrieve information or perform operations.

---

# 39. Tool Architecture

The model should not directly manipulate the repository.

Instead expose controlled tools.

Example tools:

```text
RepositorySearchTool
SymbolLookupTool
DependencyLookupTool
CallGraphTool
SourceInspectionTool
GitHistoryTool
TestLookupTool
ArchitectureQueryTool
EvidenceQueryTool
KnowledgeModelTool
UserKnowledgeTool
```

Example:

```text
struct FindSymbolTool: Tool {
    ...
}
```

The model requests:

```text
find_symbol(
    name: "PaymentService"
)
```

The application returns structured data.

---

# 40. Structured Tool Output

Avoid returning arbitrary text whenever possible.

Example:

```json
{
  "symbol": "PaymentService",
  "file": "payment/service.py",
  "line": 42,
  "dependencies": [
    "PaymentRepository",
    "PaymentProvider"
  ]
}
```

Structured outputs reduce ambiguity and make the system easier to verify.

Apple's Foundation Models framework supports guided generation and typed generated structures, which is useful for this architecture.

---

# 41. Tool Calling Policy

Tools should be:

### Read-only by default

The product is initially a comprehension system.

Avoid write operations.

### Narrowly scoped

Each tool performs one clear function.

### Deterministic where possible

The tool should return facts rather than interpretations.

### Evidence-producing

Tool results should be traceable to source artifacts.

---

# 42. Local Architecture

```text
┌──────────────────────────────────────────┐
│              macOS App                   │
│                                          │
│ SwiftUI                                  │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │ Codebase Model UI                    │ │
│ └──────────────────────────────────────┘ │
│                  │                       │
│ ┌────────────────▼─────────────────────┐ │
│ │ Agent Orchestrator                   │ │
│ └────────────────┬─────────────────────┘ │
│                  │                       │
│ ┌────────────────▼─────────────────────┐ │
│ │ Foundation Models                    │ │
│ └────────────────┬─────────────────────┘ │
│                  │                       │
│ ┌────────────────▼─────────────────────┐ │
│ │ Tool Layer                           │ │
│ └────────────────┬─────────────────────┘ │
│                  │                       │
│ ┌────────────────▼─────────────────────┐ │
│ │ Code Intelligence Engine             │ │
│ │ AST / LSP / Graph / Git              │ │
│ └──────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

---

# 43. GitHub Integration Architecture

Recommended:

```text
macOS App
     │
     │ OAuth / GitHub App
     ▼
GitHub
     │
     ▼
Repository contents
     │
     ▼
Local analysis
```

The GitHub integration should use least-privilege permissions.

GitHub explicitly recommends selecting only the repositories required and requesting only the minimum permissions necessary.

---

# 44. Privacy Architecture

The product deals with potentially proprietary source code.

Therefore:

## Default principle

> **Source code should remain local whenever technically possible.**

Recommended architecture:

```text
GitHub
   ↓
Local repository cache
   ↓
Local parsing
   ↓
Local code graph
   ↓
On-device Foundation Model
```

No source code should be uploaded to a third-party AI service by default.

Apple's Core AI positioning emphasizes on-device execution without server dependencies or token costs for supported workloads.

---

# 45. Cloud Escalation

Some tasks may exceed on-device capability.

Potential future architecture:

```text
                    Task
                      │
               ┌──────▼──────┐
               │ Local Model │
               └──────┬──────┘
                      │
              sufficient?
               /             \
             YES              NO
              │                │
              ▼                ▼
          On-device       Escalation
                              │
                     Private Cloud Compute
                     or configured provider
```

The user should explicitly know when sensitive information leaves the device.

---

# 46. Model Routing

Possible model tiers:

```text
Tier 0
Deterministic analysis

Tier 1
On-device Foundation Model

Tier 2
Private Cloud Compute / stronger model

Tier 3
Optional external provider
```

The application should prefer the cheapest/local mechanism capable of producing a reliable result.

---

# 47. Important Apple Constraint

The application should not assume that one fixed on-device model behavior remains identical forever.

Apple's documentation notes that the on-device model can change with OS updates and recommends testing prompts against model updates.

Therefore:

- model version must be recorded,
- evaluations must be versioned,
- prompt behavior must be regression-tested,
- Codebase Model generation must be reproducible enough to compare changes.

---

# 48. Knowledge Model Storage

Potential local database:

```text
SQLite
```

Tables:

```text
repositories
commits
files
symbols
components
relationships
claims
evidence
model_versions
open_questions
user_knowledge
learning_sessions
assessment_results
```

---

# 49. Example Claim Schema

```text
Claim

id
repository_id
subject_id
predicate
object_id
status
evidence_strength
created_at
updated_at
verified_at
source_commit
model_version
```

Example:

```text
PaymentService
depends_on
PaymentProvider

status:
VERIFIED

evidence_strength:
STRONG
```

---

# 50. Example Evidence Schema

```text
Evidence

id
claim_id
type
source
location
content_hash
commit_sha
created_at
```

Types:

```text
SOURCE
TEST
STATIC_ANALYSIS
GIT_HISTORY
DOCUMENTATION
RUNTIME
USER_ASSERTION
```

---

# 51. User Knowledge Schema

```text
KnowledgeState

user_id
concept_id
status
evidence
last_assessed
confidence
```

Status:

```text
NOT_INTRODUCED
EXPOSED
PARTIALLY_DEMONSTRATED
DEMONSTRATED
TRANSFERRED
```

---

# 52. Knowledge Model vs User Model

These must remain separate.

## Codebase Model

> What the system does.

## User Knowledge Model

> What the developer has demonstrated understanding of.

Never infer:

> "The user read this explanation, therefore they understand it."

Understanding must be demonstrated through interaction.

---

# 53. Model Update Rules

The Codebase Model may change when:

- new source evidence appears,
- static analysis changes,
- tests reveal contradictory behavior,
- Git history reveals additional context,
- user challenges a claim,
- repository commit changes.

The User Knowledge Model may change when:

- user correctly explains a concept,
- user predicts behavior,
- user solves a debugging problem,
- user explains a dependency,
- user successfully performs change-impact analysis.

---

# 54. Verification Architecture

Verification should prioritize deterministic evidence.

```text
Claim
  ↓
Can static analysis verify?
  ↓
YES → verify
  ↓
NO
  ↓
Can tests verify?
  ↓
YES → execute
  ↓
NO
  ↓
Can runtime evidence verify?
  ↓
YES → inspect
  ↓
NO
  ↓
Mark as inferred/unknown
```

The system should never manufacture certainty when evidence is unavailable.

---

# 55. Contradiction Detection

The system should continuously detect:

```text
Documentation ≠ Implementation

Test ≠ Implementation

Architecture Model ≠ Call Graph

User belief ≠ Verified behavior
```

Example:

```text
Documentation:
"All API requests require authentication."

Observed:
/internal/reconcile bypasses auth middleware.

Status:
⚠ CONTRADICTION
```

This is a high-value feature.

---

# 56. User Challenge as Verification

The user should be able to challenge:

- components,
- relationships,
- claims,
- assumptions,
- inferred intent.

The system should treat user disagreement as a hypothesis requiring investigation, not automatically as an error.

---

# 57. Technology Visibility Specification

## Visibility matrix

| Stage | Scope | Model | Evidence | Uncertainty | Agent Process | Source Detail |
|---|---|---|---|---|---|---|
| GitHub connection | High | Low | Low | Low | Low | Low |
| Analysis | High | Medium | Medium | Medium | Low | Low |
| Architecture | Medium | **High** | High | High | Low | Medium |
| Component exploration | Low | **High** | **High** | High | Low | High |
| Querying | Low | High | High | High | Low | High |
| Model updates | Medium | High | **High** | High | Low | High |
| Teaching | Low | Medium | High | High | Very Low | Medium |
| Assessment | Low | Low | Medium | High | Very Low | Low |

---

# 58. What should always be visible?

## 1. Model

What does the system believe?

## 2. Evidence

Why?

## 3. Uncertainty

Where might it be wrong?

## 4. Scope

What did it actually inspect?

## 5. Change

Why did its model change?

---

# 59. What should be progressive disclosure?

- call graph
- source references
- Git history
- dependency graph
- test evidence
- runtime traces
- alternative interpretations
- analysis methodology

---

# 60. What should remain hidden?

- raw chain-of-thought
- internal prompts
- token-level reasoning
- internal orchestration
- irrelevant tool calls
- internal retry loops
- implementation-specific agent state

---

# 61. Product Interaction Modes

The application should have four primary modes.

## Explore

> Understand the codebase.

## Investigate

> Answer a specific engineering question.

## Challenge

> Validate or dispute the model.

## Learn

> Build and test the developer's understanding.

The system can automatically transition between modes but should make the current mode clear.

---

# 62. Explore Mode

Primary UI:

```text
Architecture
    ↓
Component map
    ↓
Component details
```

Primary actions:

```text
Explore
Ask
Inspect
Trace
Challenge
```

---

# 63. Investigate Mode

The interface focuses on a question.

Example:

> "Why does this service call Redis?"

UI:

```text
Answer

Evidence

Related components

Potential contradiction

Confidence / evidence strength

[Inspect source]
[Challenge]
```

---

# 64. Challenge Mode

The system lets the user challenge the Codebase Model.

Example:

```text
Current model:

Checkout → Payment → Provider

Your claim:

"Checkout doesn't directly depend on Payment."
```

Then evidence comparison.

---

# 65. Learn Mode

The system creates an active learning session.

Example:

```text
Topic:
Payment Architecture

Goal:
Understand payment lifecycle

Progress:
██████░░░░

Current concept:
Idempotency
```

Then asks the user to reason.

---

# 66. Teaching Algorithm

Simplified:

```text
select concept
      ↓
determine knowledge state
      ↓
select teaching strategy
      ↓
ask question
      ↓
evaluate response
      ↓
identify misconception
      ↓
provide targeted feedback
      ↓
ask transfer question
      ↓
update knowledge state
```

---

# 67. Adaptive Teaching

If the user demonstrates mastery:

```text
Explanation ↓
Challenge ↑
```

If the user struggles:

```text
Challenge ↓
Explanation ↑
```

The system should adapt to demonstrated understanding rather than assuming a fixed level.

---

# 68. User-Controlled AI Intensity

The user should be able to choose:

```text
Quick
Balanced
Deep
Teaching
```

### Quick

Minimal agentic computation.

### Balanced

Evidence-backed explanations.

### Deep

More analysis and verification.

### Teaching

Active learning.

This gives advanced users control without exposing implementation details.

---

# 69. Performance Strategy

The system should aggressively avoid unnecessary agentic work.

## Cache:

- repository structure
- AST
- dependency graph
- call graph
- symbol index
- embeddings if used
- Codebase Model
- verified claims
- evidence
- previous analyses

## Recompute only when:

- code changes,
- evidence becomes stale,
- user explicitly requests re-analysis,
- contradiction appears.

---

# 70. Context Engineering

Do not put the entire repository into the model context.

Use:

```text
User question
+
Current component
+
Relevant graph neighborhood
+
Relevant evidence
+
Relevant knowledge state
```

This keeps context focused.

Apple provides context-size/token-count APIs for Foundation Models, which can be used to monitor and manage session context.

---

# 71. Agent Context

A typical investigation context should look like:

```text
Repository:
payment-service

Current component:
PaymentService

Question:
Why does it use Redis?

Relevant relationships:
PaymentService → Redis

Relevant source:
payment/service.py:82
payment/idempotency.py

Relevant tests:
test_payment_idempotency.py

Known model:
Redis used for idempotency

Open question:
Does Redis failure block payment?
```

Not:

> entire repository.

---

# 72. Cost Model

The product should optimize:

\[
\text{Knowledge Gain}
\over
\text{Inference Cost + Latency + Cognitive Load}
\]

Agentic reasoning should be treated as an expensive resource.

---

# 73. Product Metrics

## Primary metrics

### Comprehension accuracy

Can the developer correctly describe the system?

### Behavioral prediction

Can they predict what the code will do?

### Change-impact accuracy

Can they predict consequences of modifications?

### Debugging transfer

Can they solve a new problem using previously learned knowledge?

### Retention

Can they recall and apply knowledge later?

### AI independence

Can they solve problems without the AI?

---

# 74. Secondary metrics

- time to first useful mental model
- time to understand component
- number of verified claims
- evidence inspection rate
- challenge rate
- knowledge-model corrections
- teaching-session completion
- model contradiction detection
- agentic computation per successful task
- average latency
- token usage where available

---

# 75. Metrics We Should NOT Optimize Directly

Avoid optimizing for:

- number of AI messages
- number of tool calls
- conversation length
- tokens consumed
- time spent with AI
- amount of generated documentation

More interaction does not necessarily mean more learning.

---

# 76. Success Criteria

A successful user should be able to:

### After initial analysis

> Describe the major architecture.

### After exploration

> Explain key component relationships.

### After investigation

> Explain why important relationships exist.

### After teaching

> Predict system behavior.

### After mastery assessment

> Solve a novel engineering problem without AI assistance.

---

# 77. Evaluation Study

A strong research evaluation should compare:

## A — Conventional AI explanation

```text
Repository
→ RAG
→ ChatGPT-style explanation
```

## B — Full agentic loop

```text
Reconstruct
→ Verify
→ Evaluate
→ Challenge
→ Remember
→ Transfer
```

## C — Adaptive Codebase Mentor

```text
Codebase Model
→ Depth Router
→ Evidence
→ Optional Teaching
→ Persistent Knowledge
```

Hypothesis:

> C achieves a better knowledge-gain / computation ratio than B while outperforming A in comprehension and transfer.

---

# 78. Experimental Metrics

Measure:

```text
Accuracy
Retention
Transfer
False confidence
Time
Latency
Compute
User satisfaction
AI dependence
```

Especially:

\[
\text{Knowledge Efficiency}
=
\frac{\text{Verified Knowledge Gain}}
{\text{Agentic Compute}}
\]

---

# 79. MVP Scope

The MVP should be significantly smaller than the full vision.

## MVP includes

### Repository

- GitHub connection
- read-only repository access

### Code analysis

- file tree
- symbol extraction
- dependency graph
- call graph
- tests
- Git history

### Codebase Model

- components
- relationships
- claims
- evidence
- uncertainty

### UI

- architecture map
- component view
- contextual chat
- evidence inspection

### AI

- Foundation Models
- tool calling
- structured outputs

### Learning

- basic teaching mode
- question generation
- user responses
- basic knowledge state

---

# 80. MVP exclusions

Do not initially build:

- autonomous code modification
- production runtime integration
- multi-agent swarm
- full CI integration
- automatic PR creation
- advanced mastery analytics
- enterprise team knowledge sharing
- external LLM routing
- fully autonomous repository maintenance

These can come later.

---

# 81. Phase 2

Add:

- incremental model updates
- model history
- challenge mode
- contradiction detection
- Git diff analysis
- better knowledge tracking
- debugging scenarios
- change-impact exercises

---

# 82. Phase 3

Add:

- runtime traces
- production observability
- PR integration
- team knowledge
- architecture drift detection
- institutional knowledge capture
- advanced mastery evaluation

---

# 83. Future Architecture Drift Detection

Once the Codebase Model is persistent, the system can compare:

```text
Expected architecture
        vs
Actual architecture
```

Example:

```text
Architecture rule:
Payment Service should not access User DB.

Observed:
PaymentService → UserRepository
```

Result:

```text
⚠ Architecture drift
```

This expands the product from learning to continuous codebase intelligence.

---

# 84. Future Knowledge Debt Detection

The product can eventually identify:

```text
High code complexity
+
Low documentation
+
Low test coverage
+
Low developer understanding
=
High knowledge debt
```

This produces a **Knowledge Debt Map**.

Example:

```text
Authentication       LOW
Payments             MEDIUM
Reconciliation       HIGH
Legacy Import        CRITICAL
```

---

# 85. Security Requirements

The product must treat source code as sensitive.

Requirements:

- read-only GitHub access
- minimum GitHub permissions
- encrypted local storage where appropriate
- no source-code transmission without explicit user consent
- explicit cloud escalation
- credential isolation
- secret scanning
- no secrets included in model prompts
- repository access revocation
- model/evidence deletion controls

GitHub's permission model explicitly supports repository-scoped installation and least-privilege configuration.

---

# 86. Reliability Requirements

The system must distinguish:

```text
FACT
INFERENCE
UNKNOWN
CONTRADICTION
```

The AI must never silently convert:

```text
Unknown
```

into:

```text
Likely true
```

without communicating the distinction.

---

# 87. Failure Modes

## Failure: incomplete repository

Response:

```text
Model scope incomplete.

Missing:
- deployment infrastructure
- external database
- production configuration
```

---

## Failure: ambiguous architecture

Response:

```text
Two interpretations are supported.

A:
...

B:
...

Additional evidence required:
...
```

---

## Failure: contradictory evidence

Response:

```text
Implementation and documentation disagree.

Implementation:
...

Documentation:
...
```

---

## Failure: insufficient evidence

Response:

```text
I cannot establish this from the available repository evidence.
```

This should be considered a successful behavior rather than an AI failure.

---

# 88. Human-in-the-Loop Principle

The product should preserve human judgment.

The AI can:

- reconstruct
- search
- connect
- hypothesize
- verify
- teach
- assess

But the developer remains the authority for:

- architectural intent
- business context
- ambiguous requirements
- undocumented organizational knowledge
- final engineering decisions.

---

# 89. Product Philosophy

The product should avoid:

> **AI knows everything.**

Instead:

> **AI helps you investigate what is known, what is inferred, and what remains unknown.**

This creates a shared epistemic environment.

---

# 90. Core UX Principle

## Don't show the agent.

## Show the model.

The user should feel:

> "I'm exploring my codebase."

not:

> "I'm operating an AI agent."

The agent is infrastructure.

The Codebase Model is the product.

---

# 91. Core Data Flow

```text
GitHub
   │
   ▼
Repository Snapshot
   │
   ▼
Deterministic Code Analysis
   │
   ├── AST
   ├── Symbols
   ├── Dependencies
   ├── Call Graph
   ├── Tests
   └── Git
   │
   ▼
Semantic Interpretation
   │
   ▼
CODEBASE MODEL
   │
   ├── Components
   ├── Relationships
   ├── Claims
   ├── Evidence
   ├── Uncertainty
   └── Open Questions
   │
   ▼
DEPTH ROUTER
   │
   ├── Answer
   ├── Investigate
   ├── Verify
   └── Teach
   │
   ▼
USER KNOWLEDGE MODEL
   │
   ▼
MASTERY / TRANSFER
```

---

# 92. Core Product Loop

The product's fundamental loop should be:

```text
                    CODEBASE
                       │
                       ▼
                  SYSTEM MODEL
                       │
                       ▼
                  USER EXPLORES
                       │
                       ▼
                    QUESTION
                       │
                       ▼
                    EVIDENCE
                       │
                       ▼
                 MODEL REVISION
                       │
                       ▼
                 USER UNDERSTANDS
                       │
                       ▼
                    PRACTICE
                       │
                       ▼
                  INDEPENDENCE
```

This is preferable to:

```text
Ask → AI answer → Ask → AI answer
```

---

# 93. North Star Metric

The ultimate north-star metric should be:

# Verified Independent Engineering

> **The percentage of previously AI-assisted codebase concepts that the developer can correctly explain, reason about, and apply to a novel engineering task without AI assistance.**

This directly measures whether the product reduces knowledge debt.

---

# 94. Product Positioning

Possible positioning:

> **Understand the code you ship.**

or:

> **Turn unfamiliar codebases into knowledge you can own.**

or:

> **AI that teaches you the codebase instead of replacing your understanding.**

---

# 95. Final Product Thesis

The product should not attempt to make the AI maximally autonomous.

It should make the developer progressively more autonomous.

That means:

```text
AI dependency
██████████

      ↓

AI-assisted understanding
████████░░

      ↓

Guided understanding
██████░░░░

      ↓

Independent understanding
████░░░░░░

      ↓

Independent engineering
██░░░░░░░░
```

The product succeeds when the developer no longer needs the explanation.

---

# 96. Final Technical Architecture

```text
┌──────────────────────────────────────────────────────────┐
│                      MACOS APP                           │
│                                                          │
│  SwiftUI                                                 │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │                 CODEBASE MODEL UI                  │  │
│  │                                                    │  │
│  │ Architecture │ Components │ Evidence │ Learning   │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │                                │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │                 DEPTH ROUTER                       │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │                                │
│        ┌────────────────┼────────────────┐               │
│        ▼                ▼                ▼               │
│     ANSWER          INVESTIGATE        TEACH             │
│        │                │                │               │
│        └────────────────┼────────────────┘               │
│                         ▼                                │
│  ┌────────────────────────────────────────────────────┐  │
│  │             APPLE FOUNDATION MODELS               │  │
│  │                                                    │  │
│  │ On-device model │ Structured generation │ Tools  │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │                                │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │                    TOOL LAYER                      │  │
│  │                                                    │  │
│  │ Search │ Symbols │ Graph │ Git │ Tests │ Evidence │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │                                │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │              CODE INTELLIGENCE ENGINE              │  │
│  │                                                    │  │
│  │ AST │ LSP │ Dependency Graph │ Call Graph │ Git   │  │
│  └──────────────────────┬─────────────────────────────┘  │
│                         │                                │
│  ┌──────────────────────▼─────────────────────────────┐  │
│  │                LOCAL KNOWLEDGE STORE               │  │
│  │                                                    │  │
│  │ Codebase Model │ Evidence │ User Knowledge        │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
                         │
                         │ read-only
                         ▼
                 ┌─────────────────┐
                 │     GitHub      │
                 └─────────────────┘
```

---

# 97. Strategic Conclusion

The central architectural insight is:

> **The product should not be an autonomous agent that continuously reasons about the codebase. It should be a persistent knowledge system that invokes agentic reasoning only when necessary.**

The core artifact is the **Codebase Model**.

The core trust mechanism is **Evidence**.

The core adaptation mechanism is the **Depth Router**.

The core learning mechanism is **Active Teaching**.

The core long-term outcome is **Independent Engineering**.

Therefore:

```text
                    PRODUCT
                       │
                       ▼
               CODEBASE MODEL
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
       EXPLORE      VERIFY       LEARN
          │            │            │
          └────────────┼────────────┘
                       ▼
                 USER KNOWLEDGE
                       │
                       ▼
                INDEPENDENT USE
```

The AI is deliberately **not the center of the product**.

The developer's evolving understanding is.

---

# 98. One-Sentence Product Definition

> **Codebase Mentor is a macOS-native AI utility that constructs an evidence-backed, continuously evolving model of a software repository and uses that model to help developers explore, verify, challenge, and ultimately independently understand the systems they maintain.**

---

# 99. Guiding Principle

> **Don't build an AI that knows the codebase for the developer. Build an AI that helps the developer come to know the codebase—and can show them why that knowledge is trustworthy.**