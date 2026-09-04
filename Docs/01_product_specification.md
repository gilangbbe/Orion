# 01 — Product Specification

## 1. Product definition
The product name is Orion
The product helps developers understand unfamiliar or complex repositories without turning the experience into passive AI-generated documentation.

The user journey is:

```text
GitHub Repository
    ↓
Repository Analysis
    ↓
Semantic Grouping
    ↓
Codebase Mental Model
    ↓
Architectural Overview
    ↓
Explore Components
    ↓
Ask Questions
    ↓
MLX Agent
    ↓
Simple → Local MLX
Complex → Claude Code
    ↓
Updated Knowledge Model
    ↓
Teaching Mode
    ↓
Challenge / Assessment
    ↓
Developer Understanding
```

## 2. Product goals

1. Reconstruct the architecture and semantic structure of a repository.
2. Make the system's understanding inspectable through evidence and uncertainty.
3. Let developers explore components interactively.
4. Use adaptive computation so simple queries remain local and inexpensive.
5. Delegate difficult investigations to Claude Code through the MLX agent.
6. Maintain a persistent, evidence-linked Codebase Mental Model.
7. Help developers actively learn rather than merely consume explanations.

## 3. Non-goals

- Replacing the developer's IDE.
- Automatically modifying production code in the first version.
- Sending every query to Claude.
- Treating LLM output as ground truth.
- Exposing internal agent implementation as the primary user experience.

## 4. Product thesis

The product is not an AI chatbot that explains GitHub repositories. It is a knowledge reconstruction and learning system.

The central artifact is the Codebase Mental Model, not the chat transcript.

## 5. Success criteria

The system should be able to:
- identify meaningful components;
- explain their responsibilities;
- expose relationships and evidence;
- distinguish facts, interpretations, inferences, and unknowns;
- answer simple questions locally;
- escalate genuinely complex questions;
- update its model after investigation;
- create meaningful teaching interactions;
- improve developer understanding and transfer to novel scenarios.
