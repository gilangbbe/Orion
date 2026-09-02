#!/usr/bin/env bash
# =============================================================================
# run_study.sh — provision + run the Codebase Mentor feasibility study (Task 3)
#                on a clean machine that has nothing but Python.
#
# What it does, in order:
#   1. preflight  (Apple Silicon + macOS, python >= 3.9, git, disk)
#   2. venv       (reuse an active/─existing one, or create ./.venv)
#   3. deps       (pip install harness/requirements.txt)
#   4. benchmark  (clone Starlette at the pinned tag into ./vendor/, resolve anchors)
#   5. evaluate   (run -> grade -> leaderboard -> report) for the chosen models
#
# COPY TO THE OTHER MACHINE: the whole "Agent Feasibility Study/" directory
#   (harness/, benchmark/, *.md, this script). vendor/ and results/ are rebuilt.
#
# USAGE
#   ./run_study.sh                     # seed models (llama-3.2-3b, qwen3-8b), auto judge
#   MODELS=all ./run_study.sh          # full 10-model matrix (~40 GB downloads)
#   MODELS=qwen3-14b-4bit ./run_study.sh
#   JUDGE=anthropic:claude-sonnet-5 ./run_study.sh
#   VENV=/path/to/venv ./run_study.sh  # use a specific virtualenv
#
# ENV KNOBS (all optional)
#   MODELS         seed | all | comma-list of ids from harness/config/models.yaml   [seed]
#   JUDGE          auto | none | mlx:<hf_repo> | anthropic[:model]                   [auto]
#   STARLETTE_TAG  git tag/branch to pin the benchmark repo to                       [1.6.0]
#   VENV           path to a virtualenv to use/create                     [see venv step]
#   PYTHON         python executable used to *create* a venv                     [python3]
#   REQ_RELAX      1 = install loose (>=) deps instead of the pinned set             [0]
#   SKIP_INSTALL   1 = assume deps already present                                   [0]
#   SKIP_CLONE     1 = assume ./vendor/starlette already at the right commit         [0]
#   SKIP_EVAL      1 = provision only (venv + deps + repo + anchors), no model runs   [0]
#   HF_TOKEN       optional; higher HuggingFace download rate limits
#   ANTHROPIC_API_KEY  enables JUDGE=auto to pick the Anthropic judge
# =============================================================================
set -euo pipefail

# ---- locate ourselves -------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$SCRIPT_DIR/harness"
cd "$SCRIPT_DIR"

MODELS="${MODELS:-seed}"
JUDGE="${JUDGE:-auto}"
STARLETTE_TAG="${STARLETTE_TAG:-1.6.0}"
PYTHON="${PYTHON:-python3}"
REQ_RELAX="${REQ_RELAX:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SKIP_CLONE="${SKIP_CLONE:-0}"
SKIP_EVAL="${SKIP_EVAL:-0}"

say()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$HARNESS_DIR/orion_eval" ] || die "run this from inside the 'Agent Feasibility Study' dir (harness/ not found)"

# ---- 1. preflight ---------------------------------------------------------------
say "1/5  preflight"

OS="$(uname -s)"; ARCH="$(uname -m)"
info "host: $OS $ARCH"
if [ "$OS" != "Darwin" ] || [ "$ARCH" != "arm64" ]; then
  die "MLX runs only on Apple Silicon macOS. This host is $OS/$ARCH.
       Move to an M-series Mac, or port the harness to another runtime (mlx_lm is the
       only hard tie — runner.py is the single file to swap)."
fi
info "macOS: $(sw_vers -productVersion 2>/dev/null || echo '?')  |  memory: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1000000000 )) GB"

command -v git >/dev/null 2>&1 || die "git not found. Install the Xcode Command Line Tools:  xcode-select --install"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  # fall back to 'python' if 'python3' is absent
  command -v python >/dev/null 2>&1 && PYTHON=python || die "no python3 / python on PATH"
fi
PYVER="$("$PYTHON" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
info "python: $PYVER ($("$PYTHON" -c 'import sys;print(sys.executable)'))"
"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,9) else 1)' \
  || die "need Python >= 3.9 (have $PYVER)"

FREE_GB="$(df -g "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
info "free disk here: ${FREE_GB:-?} GB"
if [ "$MODELS" = "all" ] && [ -n "${FREE_GB:-}" ] && [ "$FREE_GB" -lt 60 ]; then
  info "WARNING: MODELS=all downloads ~40 GB of weights; <60 GB free is tight."
fi

# ---- 2. virtualenv ------------------------------------------------------------
say "2/5  virtualenv"

if [ -n "${VENV:-}" ]; then
  VENV_DIR="$VENV"; info "using VENV=$VENV_DIR"
elif [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
  VENV_DIR="$VIRTUAL_ENV"; info "using the already-activated venv ($VENV_DIR)"
elif [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
  VENV_DIR="$SCRIPT_DIR/.venv"; info "found $VENV_DIR"
elif [ -x "$SCRIPT_DIR/../.venv/bin/python" ]; then
  VENV_DIR="$SCRIPT_DIR/../.venv"; info "found $VENV_DIR"
else
  VENV_DIR="$SCRIPT_DIR/.venv"
fi

if [ ! -x "$VENV_DIR/bin/python" ]; then
  info "creating venv at $VENV_DIR"
  "$PYTHON" -m venv "$VENV_DIR" || die "python -m venv failed (install the 'venv' module)"
fi
PY="$VENV_DIR/bin/python"
info "venv python: $("$PY" -c 'import sys;print(sys.executable)')"

# ---- 3. dependencies -------------------------------------------------------------
say "3/5  dependencies"
if [ "$SKIP_INSTALL" = "1" ]; then
  info "SKIP_INSTALL=1 — not touching packages"
else
  "$PY" -m pip install --quiet --upgrade pip
  if [ "$REQ_RELAX" = "1" ]; then
    info "installing loose (>=) deps"
    "$PY" -m pip install --quiet \
      "mlx-lm>=0.28,<0.40" "mlflow>=3.4" "pyyaml>=6.0" "jsonschema>=4.20" "psutil>=5.9"
  else
    info "installing pinned deps from harness/requirements.txt"
    "$PY" -m pip install --quiet -r "$HARNESS_DIR/requirements.txt"
  fi
  "$PY" - <<'PYEOF'
import mlx_lm, mlx.core as mx, mlflow, yaml, jsonschema, psutil
print(f"    mlx-lm {mlx_lm.__version__} | mlx {mx.__version__} | mlflow {mlflow.__version__}")
PYEOF
fi

RUN() { PYTHONPATH="$HARNESS_DIR" "$PY" -m orion_eval.cli "$@"; }

# ---- 4. benchmark repo -----------------------------------------------------------
say "4/5  benchmark repo (Starlette @ $STARLETTE_TAG)"
VENDOR="$SCRIPT_DIR/vendor/starlette"
if [ "$SKIP_CLONE" = "1" ] && [ -d "$VENDOR/.git" ]; then
  info "SKIP_CLONE=1 — using existing $VENDOR"
else
  if [ -d "$VENDOR/.git" ]; then
    info "fetching + checking out $STARLETTE_TAG in existing clone"
    git -C "$VENDOR" fetch --quiet --tags --depth 1 origin "$STARLETTE_TAG" || true
    git -C "$VENDOR" checkout --quiet "$STARLETTE_TAG" 2>/dev/null \
      || git -C "$VENDOR" checkout --quiet "FETCH_HEAD"
  else
    mkdir -p "$SCRIPT_DIR/vendor"
    ( git clone --quiet --depth 1 --branch "$STARLETTE_TAG" \
        https://github.com/Kludex/starlette.git "$VENDOR" 2>/dev/null ) \
      || ( git clone --quiet --depth 1 --branch "v$STARLETTE_TAG" \
             https://github.com/Kludex/starlette.git "$VENDOR" ) \
      || die "could not clone Starlette at tag '$STARLETTE_TAG' (tried '$STARLETTE_TAG' and 'v$STARLETTE_TAG')"
  fi
fi
SHA="$(git -C "$VENDOR" rev-parse HEAD)"
info "pinned commit: $SHA"

info "resolving evidence anchors -> benchmark/benchmark.resolved.json"
RUN resolve-anchors

# ---- judge selection -----------------------------------------------------------
if [ "$JUDGE" = "auto" ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    JUDGE="anthropic:claude-sonnet-5"
    "$PY" -m pip install --quiet "anthropic>=0.40" || info "note: 'pip install anthropic' failed; grade step may fall back"
  else
    JUDGE="mlx:mlx-community/Qwen3-8B-4bit"
  fi
fi
info "judge: $JUDGE"
case "$JUDGE" in
  mlx:*) info "  (local model judge — for a stronger pass use JUDGE=mlx:mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit or an Anthropic key)";;
esac

# ---- 5. evaluate -------------------------------------------------------------
if [ "$SKIP_EVAL" = "1" ]; then
  say "5/5  evaluate — SKIPPED (SKIP_EVAL=1)"
  info "provisioned. run the eval later with:"
  info "  SKIP_INSTALL=1 SKIP_CLONE=1 MODELS=$MODELS ./run_study.sh"
  exit 0
fi
say "5/5  evaluate   models=$MODELS"
info "downloads happen lazily on first use of each model; this can take a while."
RUN run --model "$MODELS"
RUN grade --judge "$JUDGE"
RUN leaderboard
RUN report

# ---- done ---------------------------------------------------------------------
say "done"
cat <<EOF
    leaderboard : $SCRIPT_DIR/results/LEADERBOARD.md
    review UI   : $SCRIPT_DIR/results/review.html      (open in a browser)
    per-model   : $SCRIPT_DIR/results/<model>/{answers,grades}.jsonl
    mlflow      : mlflow ui --backend-store-uri "sqlite:///$SCRIPT_DIR/results/mlflow.db"

    benchmark commit: $SHA
    judge used      : $JUDGE
EOF
if [ "$MODELS" = "seed" ]; then
  info "this was the 2-model seed set. Re-run with  MODELS=all  for the full matrix,"
  info "ideally with a stronger judge, before drawing Task 3 conclusions."
fi
