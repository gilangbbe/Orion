# BENCHMARK.md

**Deliverable for Task 2 — Codebase Benchmark**
Project: *Codebase Mentor* / Local LLM & Agent Feasibility Study
Companion machine-readable dataset: [`benchmark/benchmark.json`](benchmark/benchmark.json)
JSON Schema: [`benchmark/questions.schema.json`](benchmark/questions.schema.json)
Date compiled: 2026-09-02

---

## 1. What this is

A fixed benchmark that **every model, context strategy, and agent configuration in the study
runs against unchanged**. It is a single real repository plus 55 questions with established
ground truth, spanning the nine reasoning categories the study requires.

The benchmark is deliberately **not** a code-generation test. Per study rule #6, it is built to
separate *models that can reason about a software system* from *models that produce
plausible-sounding prose about code*.

---

## 2. Repository under test

| Field | Value |
|---|---|
| Repository | **Starlette** — a lightweight ASGI framework / toolkit for Python |
| Canonical remote | `https://github.com/Kludex/starlette` (formerly `encode/starlette`; old URLs redirect — **confirm at pin time**) |
| Pinned version | **`v1.6.0`** (latest stable as of 2026-08-08) |
| Pinned commit | **RECORD AT CLONE TIME:** `git -C starlette rev-parse HEAD` → write the SHA into `benchmark/benchmark.json` `metadata.commit_sha` |
| Language | Python (100%), fully type-annotated |
| Approx size | ~9–11k LOC in `starlette/`, plus `tests/` and `docs/` |
| Runtime deps | `anyio` only (hard). Optional: `python-multipart`, `itsdangerous`, `jinja2`, `httpx`, `pyyaml` |
| License | BSD-3-Clause |

### Why Starlette

1. **Genuine architecture, small surface.** A real request/response lifecycle, a layered
   middleware stack, a routing tree with sub-application mounting, background tasks, WebSockets,
   lifespan/events, class-based endpoints — but small enough that Task 5 can put a meaningful
   fraction (or all) of the source in context.
2. **Cross-file reasoning is unavoidable.** Answering "how does an unhandled exception become a
   500?" requires connecting `applications.py`, `middleware/errors.py`,
   `middleware/exceptions.py`, `_exception_handler.py`, and `routing.py`.
3. **Self-contained.** One hard dependency (`anyio`). Reasoning about data flow does not bottom
   out in a third-party package the way a Django/FastAPI app would.
4. **Documentation exists and is specific** — `docs/` makes concrete behavioural claims
   (middleware order, exception handling, `BaseHTTPMiddleware` limitations), which enables real
   contradiction-detection questions instead of contrived ones.
5. **Well-known gotchas.** The framework has a set of documented and folklore "surprises"
   (middleware sits outside the exception handlers; background tasks run after the response;
   `BaseHTTPMiddleware` breaks contextvar propagation; `redirect_slashes` is a 307). These make
   excellent behavioural-reasoning, misconception, and teaching items.
6. **Stable core.** The architecture targeted here has been essentially unchanged since the
   0.20 era, so ground truth is robust to minor version drift.

### Repository Scope Contract (mirrors Product Spec §9)

```
Analyzed
  ✓ starlette/**       (source of truth for all questions)
  ✓ tests/**           (behavioural evidence)
  ✓ docs/**            (documentation-vs-implementation questions)
  ✓ git metadata       (history/why questions — optional evidence)

Not analyzed / out of scope
  ○ anyio internals and other third-party packages
  ○ CI config, packaging, tooling
  ○ Any runtime/production deployment
  ○ Network / event-loop behaviour of a specific ASGI server (uvicorn, hypercorn)
```

A model answer that depends on `anyio` or uvicorn internals to be *correct* is out of scope and
should be graded as under-evidenced.

---

## 3. Pinning & setup procedure

```bash
# 1. Clone at the pinned tag
git clone https://github.com/Kludex/starlette
cd starlette && git checkout v1.6.0
git rev-parse HEAD          # <-- paste into benchmark.json metadata.commit_sha

# 2. Resolve evidence line anchors against THIS checkout (line_hint values in the
#    dataset are unverified estimates; symbols are authoritative). See tools/resolve_anchors.py
#    stub described in §6.
```

**Line numbers vs symbols.** Every `evidence` entry carries a **`symbol`** anchor
(`path::Qualified.Name`) which is authoritative and stable, plus an optional integer
**`line_hint`**. The `line_hint` values were captured from the `master` branch during dataset
authoring and are **not guaranteed** to match `v1.6.0`. Graders and the eventual harness must
resolve real line numbers by locating the symbol in the pinned checkout. This mirrors the
Product Spec's evidence model (§13, §50): evidence is `{type, source, location, commit_sha}`
and `location` is resolved against a specific commit.

---

## 4. Question categories (55 items)

| Code | Category | Count | What it probes |
|---|---|---:|---|
| `CU` | `code_understanding` | 9 | What a single function / class / method does |
| `XF` | `cross_file_reasoning` | 8 | How component A interacts with component B across files |
| `AR` | `architecture` | 6 | Major components, layering, primary data flow, boundaries |
| `DC` | `dependency_change_impact` | 6 | What breaks if symbol / signature / behaviour X changes |
| `BR` | `behavioral_reasoning` | 9 | What actually happens at runtime under condition X |
| `CD` | `contradiction_detection` | 5 | Does `docs/` agree with `starlette/`? Where not? |
| `EV` | `evidence` | 4 | Which files / symbols / tests substantiate a given claim |
| `TE` | `teaching` | 4 | Is this developer's explanation correct? Correct the misconception |
| `TR` | `transfer` | 4 | Novel scenario: reason about the system, predict behaviour |

Full text of every item is in [`benchmark/benchmark.json`](benchmark/benchmark.json). A
human-readable summary follows in §7.

---

## 5. Ground-truth record (per Product Spec §77 / study Task 2)

Each item in `benchmark.json` has:

```
id                    stable id, e.g. "BR-04"
category              one of the nine category slugs
question              the prompt given to the model (verbatim, context added separately)
expected_answer       reference answer — concise but complete; the rubric target
required_concepts     [ ... ] concepts a full-credit answer MUST demonstrate
relevant_files        [ ... ] repo-relative paths the answer should rest on
relevant_symbols      [ ... ] "path::Qualified.Name" anchors
evidence              [ {file, symbol, line_hint|null, type} ]  type ∈ SOURCE|TEST|DOC|GIT_HISTORY|STATIC_ANALYSIS
common_misconceptions [ ... ] wrong answers that sound right — used to detect confident error
answerable_from       source_only | source+docs | source+tests   (drives Task 4 context design)
difficulty            easy | medium | hard
points                integer weight (default 1)
grading_notes         how to score; what counts as hallucination for this item
```

### Scoring rubric (applied to every answer, 0–2 per axis unless noted)

| Axis | 0 | 1 | 2 |
|---|---|---|---|
| **Correctness** | Wrong / contradicts source | Partially correct, key error | Matches `expected_answer` |
| **Completeness** | Misses most `required_concepts` | Covers some | Covers all `required_concepts` |
| **Architectural reasoning** | No mechanism, just restates question | Names components, weak on interaction | Correct mechanism + interaction |
| **Hallucination** (penalty, −0..−2) | Invents symbols/files/behaviour, or asserts a `common_misconception` with confidence | One minor unsupported claim | None |
| **Evidence accuracy** | Cites nothing or wrong files | Right area, imprecise | Cites the `relevant_symbols` / correct files |
| **Structured-output reliability** (Task 3+ only) | Invalid JSON / schema fail | Valid but lossy | Valid, complete |
| **Teaching quality** (`TE`/`TR` only) | Rubber-stamps or misleads | Identifies issue, weak correction | Identifies precisely + corrects + gives a check |

**Composite:** report per-axis means and a normalized total. Do **not** collapse to one number
before analysis. A model that scores high on Correctness but also high on Hallucination (i.e.
right *and* wrong confidently) must be visible as such — this is the single most important
signal for a product whose thesis is epistemic honesty (Product Spec §3, §86).

### "Successful uncertainty" is a correct answer

For items where `expected_answer` is *"the repository does not determine this"* (a few `BR`/`EV`
items include an out-of-scope trap), a model that says so scores full Correctness. A model that
manufactures a confident answer scores 0 and takes a Hallucination penalty (Product Spec §87).

---

## 6. Harness hooks (built in a later task, described here for completeness)

Not implemented in this deliverable (scope: Task 1 + Task 2 only). The dataset is shaped so the
Task 3 harness can:

- `tools/resolve_anchors.py` — for each `evidence.symbol`, grep the pinned checkout, fill real
  `line` numbers, emit `benchmark.resolved.json`.
- `tools/run_eval.py` — iterate models × items, capture answer + latency + tokens + peak RSS,
  log to MLflow (one run per model/quant/strategy; one nested run per item).
- `tools/grade.py` — LLM-as-judge against the rubric with a stronger model, plus exact-match
  checks on `relevant_symbols` for the Evidence axis; human spot-check sample ≥ 20%.

---

## 7. Question summary (human-readable)

> Reference answers, required concepts, evidence anchors and misconceptions for each item are in
> [`benchmark/benchmark.json`](benchmark/benchmark.json). This section is an index.

### Code understanding (`CU`)

| id | Question | Key files |
|---|---|---|
| CU-01 | What does `Starlette.build_middleware_stack()` do, and in what order are layers applied? | `applications.py` |
| CU-02 | What does `ServerErrorMiddleware.__call__` do when the wrapped app raises, in debug vs non-debug? | `middleware/errors.py` |
| CU-03 | What is the responsibility of `ExceptionMiddleware`, and which exceptions does it handle by default? | `middleware/exceptions.py` |
| CU-04 | What does `Route.matches()` return, and what does a `Match.PARTIAL` result mean? | `routing.py` |
| CU-05 | What does `Request.stream()` do, and how does it prevent the body being consumed twice? | `requests.py` |
| CU-06 | What does `Request.body()` do differently from `Request.stream()` on repeat calls? | `requests.py` |
| CU-07 | What does `BackgroundTasks.__call__` do, and how are sync vs async task functions run? | `background.py`, `concurrency.py` |
| CU-08 | What does `RedirectResponse` default its status code to, and why does that choice matter? | `responses.py` |
| CU-09 | What does `Config.__call__` do when a key is set both in the environment and in the `.env` file? | `config.py` |

### Cross-file reasoning (`XF`)

| id | Question | Key files |
|---|---|---|
| XF-01 | Trace how an unhandled `ValueError` raised in an endpoint becomes an HTTP 500 response. | `applications.py`, `middleware/errors.py`, `routing.py` |
| XF-02 | How do `ExceptionMiddleware` and `routing.py` cooperate to turn a raised `HTTPException` into a response? | `middleware/exceptions.py`, `_exception_handler.py`, `routing.py` |
| XF-03 | How does `Mount` interact with `Router` so a sub-application only sees its sub-path? | `routing.py` |
| XF-04 | How does `Starlette.add_middleware` relate to `build_middleware_stack`, and why does adding middleware after startup raise? | `applications.py` |
| XF-05 | How does a class-based `HTTPEndpoint` end up being called by a `Route`? | `routing.py`, `endpoints.py` |
| XF-06 | How does `request.state` relate to lifespan-yielded state and `scope["state"]`? | `requests.py`, `routing.py`, `applications.py` |
| XF-07 | How does `TestClient` run the app, and when is the lifespan actually executed? | `testclient.py` |
| XF-08 | How does `CORSMiddleware` short-circuit a preflight request before routing runs? | `middleware/cors.py`, `applications.py` |

### Architecture (`AR`)

| id | Question | Key files |
|---|---|---|
| AR-01 | What are the major components of Starlette and how are they layered for an HTTP request? | many |
| AR-02 | Describe the primary data flow from ASGI `scope/receive/send` to an endpoint and back. | `applications.py`, `routing.py`, `requests.py`, `responses.py` |
| AR-03 | Where are the system boundaries — what does Starlette delegate to the ASGI server and to `anyio`? | `concurrency.py`, `applications.py` |
| AR-04 | What is the role of the middleware stack vs the routing tree — why are they different mechanisms? | `applications.py`, `routing.py`, `middleware/` |
| AR-05 | How does the WebSocket path diverge from the HTTP path through the same stack? | `routing.py`, `websockets.py`, `middleware/exceptions.py` |
| AR-06 | What are the critical entry points a new maintainer should read first, and why? | `applications.py`, `routing.py` |

### Dependency / change impact (`DC`)

| id | Question | Key files |
|---|---|---|
| DC-01 | What breaks if `Request.__init__` starts requiring a non-empty `receive` channel argument? | `requests.py`, `routing.py`, `testclient.py` |
| DC-02 | If `ServerErrorMiddleware` stopped re-raising after sending the 500, what downstream behaviour changes? | `middleware/errors.py`, `testclient.py` |
| DC-03 | What depends on `Match` being an ordered enum where `FULL > PARTIAL > NONE`? | `routing.py` |
| DC-04 | If `BackgroundTasks` were changed to run tasks concurrently instead of sequentially, what could break? | `background.py` |
| DC-05 | What is the blast radius of changing `JSONResponse` default separators or `media_type`? | `responses.py` |
| DC-06 | If `build_middleware_stack` moved `ExceptionMiddleware` to the outside of user middleware, what changes for app authors? | `applications.py`, `middleware/exceptions.py` |

### Behavioral reasoning (`BR`)

| id | Question | Key files |
|---|---|---|
| BR-01 | An endpoint raises `HTTPException(404)`. A user middleware (plain ASGI) above it also raises `HTTPException(400)` on some requests. Which produces a clean 4xx and which produces a 500, and why? | `middleware/exceptions.py`, `middleware/errors.py`, `applications.py` |
| BR-02 | A request matches a path but uses `DELETE` on a `GET`-only route. What status, what headers, and which code path? | `routing.py` |
| BR-03 | Client requests `/items` but the route is `/items/`. What happens with default settings? What if `redirect_slashes=False`? | `routing.py` |
| BR-04 | A background task list has three tasks; the second raises. What does the client see, and do task 1 and task 3 run? | `background.py`, `responses.py` |
| BR-05 | Endpoint calls `await request.json()` then `await request.body()`. Does the second call fail? What about `.stream()` twice? | `requests.py` |
| BR-06 | A contextvar is set inside a `BaseHTTPMiddleware.dispatch` after `call_next`. Is it visible to code outside the middleware? | `middleware/base.py` |
| BR-07 | `GZipMiddleware` is installed; a handler returns a 120-byte JSON response with `Accept-Encoding: gzip`. Is it compressed? | `middleware/gzip.py` |
| BR-08 | `CORSMiddleware(allow_origins=["*"], allow_credentials=True)`; a credentialed cross-origin request arrives. What ACAO header is sent? | `middleware/cors.py` |
| BR-09 | App defined with `lifespan` that raises during startup. What happens when served, and what happens under `TestClient`? | `routing.py`, `testclient.py` |

### Contradiction detection (`CD`)

| id | Question | Key files |
|---|---|---|
| CD-01 | `docs/middleware.md` shows the execution order as `ServerErrorMiddleware → user middleware → ExceptionMiddleware → Routing`. Does `build_middleware_stack` implement exactly that? Any gap the docs don't state? | `docs/middleware.md`, `applications.py` |
| CD-02 | Do the docs anywhere warn that exceptions raised *in* middleware bypass `ExceptionMiddleware`? Does the code behave that way regardless? | `docs/middleware.md`, `docs/exceptions.md`, `applications.py` |
| CD-03 | `docs/background.md` vs `background.py`: is the documented ordering ("after the response") and error behaviour fully accurate? | `docs/background.md`, `background.py` |
| CD-04 | `docs/requests.md` description of `Request.body()`/`stream()` caching vs the implementation — any mismatch or omission? | `docs/requests.md`, `requests.py` |
| CD-05 | `docs/middleware.md` `BaseHTTPMiddleware` "Limitations" section vs `middleware/base.py` — is the stated contextvar limitation the only relevant one? | `docs/middleware.md`, `middleware/base.py` |

### Evidence (`EV`)

| id | Question | Key files |
|---|---|---|
| EV-01 | What evidence in the repository supports the claim "`ServerErrorMiddleware` is always the outermost layer"? | `applications.py`, `docs/middleware.md`, `tests/` |
| EV-02 | What evidence supports "a partial route match yields 405 with an `Allow` header"? Cite source and tests. | `routing.py`, `tests/test_routing.py` |
| EV-03 | What evidence supports "background tasks run after the response is sent"? | `responses.py`, `background.py`, `tests/test_background.py` |
| EV-04 | What evidence supports "`TestClient` triggers lifespan only when used as a context manager"? | `testclient.py`, `tests/` |

### Teaching (`TE`)

| id | Developer explanation to assess | Verdict target |
|---|---|---|
| TE-01 | "If I register `@app.exception_handler(HTTPException)`, it will catch any `HTTPException` I raise, including from my custom middleware." | Incorrect — only catches those raised *inside* routing/endpoints (i.e. inside `ExceptionMiddleware`). |
| TE-02 | "Background tasks are a good place to send the user a different response if something fails." | Incorrect — response is already sent; background runs after. |
| TE-03 | "`redirect_slashes` sends a 301 so browsers cache it." | Incorrect — it's a 307; method and body preserved, not a permanent redirect. |
| TE-04 | "Mounting a sub-app under `/v1` means the sub-app's routes must be declared as `/v1/...`." | Incorrect — the sub-app sees the stripped path; `root_path` carries the prefix. |

### Transfer (`TR`)

| id | Novel scenario | What a correct answer must establish |
|---|---|---|
| TR-01 | "A request reaches my endpoint but `request.headers` shows a header my middleware deleted. Diagnose where the deletion could and could not take effect." | Understands middleware ordering, that `Headers` is immutable, that plain ASGI middleware mutates `scope["headers"]` before routing, and that `Request` reads from `scope` lazily. |
| TR-02 | "We want a 500 to also emit a JSON body for API clients instead of plain text. Where do we hook, and what must we be careful of?" | Register a handler for `Exception`/500 or `500` status; it's invoked by `ServerErrorMiddleware`; must not itself raise; debug mode changes behaviour; re-raise semantics for logging. |
| TR-03 | "Under load, some responses are missing a header our `BaseHTTPMiddleware` adds. Hypothesize causes." | Streaming-response / early-send interaction, exception path bypassing `dispatch`'s post-processing, contextvar/propagation limitation, ordering vs other middleware. |
| TR-04 | "We add a mounted sub-application; now `request.url_for()` in the sub-app produces wrong URLs behind our proxy. Reason about root_path." | `Mount` accumulates `root_path`; `url_for` uses it; proxy/ASGI-server `root_path` must be set; `app_root_path` vs `root_path` distinction. |

---

## 8. Coverage against study Task 2 requirements

| Task 2 required category | Covered by |
|---|---|
| Code understanding — what does this function/component do | `CU-01..09` |
| Cross-file reasoning — how does A interact with B | `XF-01..08` |
| Architecture — major components, main data flow | `AR-01..06` |
| Dependency / change impact — what could break if X changes | `DC-01..06` |
| Behavioral reasoning — what happens under condition X | `BR-01..09` |
| Contradiction detection — docs vs implementation | `CD-01..05` |
| Evidence — what evidence supports the answer | `EV-01..04`; also every other item carries an `evidence` array |
| Teaching — is this developer explanation correct | `TE-01..04` |
| Transfer — given a new scenario, can the developer reason | `TR-01..04` |

## 9. Known limitations of this benchmark

- **One repository, one language.** Findings about model capability generalize only to
  Python / ASGI-style codebases. A second repo (a different language, a data-flow-heavy CLI)
  should be added before any cross-language claim.
- **55 items is enough to rank, not enough for tight confidence intervals** on per-category
  differences between similar models. Treat small gaps as noise.
- **`line_hint` values are unverified** (see §3). The harness must resolve them.
- **Grading is partly LLM-assisted**, which introduces judge bias. The rubric mandates ≥ 20%
  human review and exact-match scoring on the Evidence axis to bound this.
- **No runtime evidence.** Every item is answerable from static artifacts (source/tests/docs/
  git). Runtime-trace questions are out of scope for this phase (Product Spec §15, Phase 3).

---

## 10. Sources

- [Starlette repository](https://github.com/Kludex/starlette) (formerly [encode/starlette](https://github.com/encode/starlette))
- [Starlette documentation](https://www.starlette.io/) · `docs/` in-repo
- [Starlette release notes](https://github.com/Kludex/starlette/blob/main/docs/release-notes.md)
- Source files read while authoring this benchmark (master branch, 2026-09-02):
  `starlette/applications.py`, `starlette/middleware/errors.py`, `starlette/middleware/exceptions.py`,
  `starlette/routing.py`, `starlette/requests.py`, `starlette/background.py`, `docs/middleware.md`
