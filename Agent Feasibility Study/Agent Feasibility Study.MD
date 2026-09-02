# Local LLM & Agent Feasibility Study

### Objective

Determine the **best technical foundation for the product before building the product itself**.

The project is constrained to **MLX Community models** and is intended to run locally on Apple Silicon.

We are **not building the macOS application yet**. The goal of this phase is to answer:

1. Which MLX model is capable enough?
2. How much context does it need?
3. Should we use direct prompting, RAG, or structured Codebase Model context?
4. When does tool use / agentic reasoning improve results?
5. Can the selected model support teaching and knowledge assessment?

---

## TASK 1 — Model Discovery & Benchmarking

**Task:** Identify candidate MLX Community models.

Select a representative range:

* Small: ~3–8B
* Medium: ~12–32B
* Large: ~70B+

For each candidate, record:

* Model size
* Quantization options
* Context length
* MLX compatibility
* Memory requirements
* Inference speed
* Tool/structured-output capability
* License

**Deliverable:** `MODEL_CANDIDATES.md`

Do **not** choose a winner yet.

---

# TASK 2 — Codebase Benchmark

**Task:** Create the benchmark that every model will use.

Select **one real open-source repository** with enough complexity to require genuine code understanding.

Create approximately **50 questions**, covering:

### Code understanding

* What does this function/component do?

### Cross-file reasoning

* How does component A interact with component B?

### Architecture

* What are the major components?
* What is the main data flow?

### Dependency/change impact

* What could break if component X changes?

### Behavioral reasoning

* What happens under condition X?

### Contradiction detection

* Does the documentation agree with the implementation?

### Evidence

* What evidence supports the answer?

### Teaching

* Is this developer explanation correct?

### Transfer

* Given a new scenario, can the developer reason about the system?

For every question, establish **ground truth**:

```text
Question
Expected answer
Required concepts
Relevant files
Relevant symbols
Evidence
Common misconceptions
```

**Deliverable:** `BENCHMARK.md` + machine-readable benchmark dataset.

---

# TASK 3 — Baseline LLM Evaluation

**Task:** Test all candidate models against the same benchmark.

Initially, **do not introduce RAG or agents**.

Give the model controlled source context and evaluate:

* Correctness
* Completeness
* Architectural reasoning
* Hallucination
* Evidence accuracy
* Structured-output reliability
* Teaching/evaluation quality

Also measure:

* Model loading time
* Time to first token
* Tokens/sec
* Total latency
* Peak memory

**Deliverable:** Model leaderboard. preferably MLFlow experiments

The output should tell us:

> Which models are actually capable of reasoning about software systems, not merely generating plausible code explanations?

---

# Task 4 — Context Strategy Experiment

Once the baseline is established, compare three approaches.

### A — Direct / ChatGPT-style

```text
Question
+
Relevant source code
        ↓
      Model
        ↓
     Answer
```

### B — RAG

```text
Question
 ↓
Retrieve relevant code
 ↓
Model
 ↓
Answer
```

### C — Structured Codebase Context

```text
Question
 ↓
Code structure
+
Relationships
+
Relevant source
+
Evidence
 ↓
Model
 ↓
Answer
```

Compare all three using the **same questions and same model**.

Measure:

* Answer accuracy
* Completeness
* Evidence grounding
* Architectural understanding
* Hallucination
* Context size
* Latency

**Deliverable:** `CONTEXT_STRATEGY_REPORT.md`

The objective is to determine whether our hypothesis is valid:

> **A structured representation of the codebase provides better reasoning context than retrieving raw code alone.**

---

# Task 5 — Context Scaling Experiment

**Task:** Determine how model performance changes as repository context grows.

Test approximately:

```text
1K → 4K → 8K → 16K → 32K → 64K → 128K
```

where supported.

Measure:

* Accuracy
* Completeness
* Hallucination
* Latency
* Memory
* Retrieval requirements

We want to determine whether:

> "Just give the LLM more code"

is actually a viable architecture.

**Deliverable:** Context-performance curve and recommendation.

---

# Task 6 — Agentic / Tool-Use Experiment

Only after the previous experiments.

Create basic tools such as:

```text
find_symbol()
find_callers()
find_dependencies()
read_source()
find_tests()
get_git_history()
```

Compare:

### Direct

```text
Question → Model → Answer
```

### Retrieval

```text
Question → Retrieval → Model → Answer
```

### Agentic

```text
Question
 ↓
Model
 ↓
Tool
 ↓
Model
 ↓
Tool
 ↓
Model
 ↓
Answer
```

Measure:

* Answer quality
* Tool-selection accuracy
* Number of tool calls
* Unnecessary calls
* Latency
* Compute cost

The goal is **not** to prove that agents are better.

The goal is to determine:

> **Which questions actually benefit from agentic investigation?**

---

# Task 7 — Teaching Experiment

Finally, test the actual product thesis.

Compare:

### Condition A — Explanation only

```text
Question
 ↓
AI explanation
```

### Condition B — Explanation + Challenge

```text
Question
 ↓
Explanation
 ↓
Developer answers question
 ↓
AI evaluates
```

### Condition C — Teaching + Transfer

```text
Explanation
 ↓
Question
 ↓
Developer prediction
 ↓
Evaluation
 ↓
Novel scenario
 ↓
Developer solves independently
```

Measure **developer performance**, not conversation quality:

* Understanding
* Recall
* Architectural reasoning
* Debugging
* Change-impact reasoning
* Novel-scenario transfer

The key question:

> **Does active engagement produce better transferable understanding than simply receiving an AI explanation?**

---

# Final Deliverable

At the end, each task should produce one technical recommendation answering:

### 1. Model

> Which MLX Community model should we initially target?

### 2. Quantization

> Which quantization provides the best quality/performance tradeoff?

### 3. Context strategy

> Direct prompting, RAG, structured Codebase Model, or hybrid?

### 4. Context size

> How much information should be provided to the model?

### 5. Agentic depth

> Which tasks require tool use or multi-step reasoning?

### 6. Teaching capability

> Is the selected model reliable enough to evaluate developer understanding?

### 7. Hardware requirements

> What Apple Silicon configuration is required for an acceptable experience?

### 8. Architecture recommendation

Produce the first evidence-based architecture:

```text
Repository
    ↓
Code Intelligence
    ↓
Context / Retrieval
    ↓
MLX Model
    ↓
Reasoning / Generation
    ↓
Agentic Tools (if justified)
    ↓
Learning System
```

---

## Rules for the task

**1. No production app yet.**

**2. No premature architecture decisions.**

**3. Don't assume RAG is necessary—test it.**

**4. Don't assume agents are necessary—test them.**

**5. Don't choose the largest model automatically.**

**6. Don't evaluate models only by how convincing their answers sound.**

**7. Every major architectural decision must be supported by benchmark results.**

**8. Keep the model layer replaceable.**

### Definition of success

At the end of Phase, we should be able to say:

> **“Given our target Apple hardware and the MLX model ecosystem, we have empirical evidence for which model, context strategy, and degree of agentic reasoning are appropriate for codebase understanding and developer learning.”**

Only **after that** should the team begin implementing the actual Codebase Mentor application.
