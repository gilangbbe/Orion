#!/usr/bin/env bash
# Exports a Qwen3 checkpoint to a Core AI language-model bundle for Orion's local backend
# (Docs/18_os27_foundation_models_coreai.md M1).
#
# The bundle lands at $ORION_COREAI_MODEL_DIR/<model>-<compression>/ (default root:
# ~/Library/Application Support/Orion/CoreAIModels) -- the same place CoreAIModelLocator
# (Sources/OrionAgent/Model/CoreAIModelLocator.swift) looks. A bundle is the folder
# CoreAILanguageModel(resourcesAt:) loads: <name>.aimodel + tokenizer + metadata.json.
#
# Usage:
#   scripts/coreai/export-qwen3.sh [--model qwen3-8b] [--compression 4bit]
#       [--max-context-length N] [--aot] [--dry-run] [--overwrite]
#
#   --model               coreai-models registry short-name (qwen3-0.6b, qwen3-4b, qwen3-8b, ...)
#   --compression         macOS preset: 4bit (default) | 4bit_weights_8bit_kv_cache | none
#   --max-context-length  override the registry's context ceiling (qwen3-8b: 40960)
#   --aot                 also AOT-compile for this Mac with `xcrun coreai-build compile` and point
#                         metadata.json at the compiled asset (models/README.md's documented step).
#                         Measured on M5 / Qwen3-8B (Docs/18 M1): slower than letting Core AI compile
#                         and cache on first load (cold 10.7s vs 8.2s, warm 2.5s vs 1.0s) at +4.3GB,
#                         so off by default.
#   --dry-run             print the resolved export config and stop
#   --overwrite           replace an existing bundle of the same name
#
# Needs: git, uv, Xcode 27 (xcrun coreai-build), network for the first Hugging Face download
# (the fp16 source checkpoint -- Qwen3-8B is ~16GB -- lands in the normal HF cache).
set -euo pipefail

# Pinned commit, not the 0.2.0 tag: 0.2.0 depends on xgrammar `branch: "main"` (SwiftPM rejects that
# under a version-pinned dependency, which M2 needs) and lacks the 4bit_weights_8bit_kv_cache
# preset M4 compares. Export and Swift runtime must come from the same revision (bundle format).
COREAI_MODELS_REV="e7b24da85ea64a77d26324d7ce9607de9b955f57"
COREAI_MODELS_DIR="${COREAI_MODELS_DIR:-$HOME/Library/Caches/Orion/coreai-models}"
OUT_ROOT="${ORION_COREAI_MODEL_DIR:-$HOME/Library/Application Support/Orion/CoreAIModels}"

model="qwen3-8b"
compression="4bit"
max_context=""
aot=0
dry_run=0
overwrite=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) model="$2"; shift 2 ;;
        --compression) compression="$2"; shift 2 ;;
        --max-context-length) max_context="$2"; shift 2 ;;
        --aot) aot=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --overwrite) overwrite=1; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in git uv xcrun; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

name="${model}-${compression}"
bundle="$OUT_ROOT/$name"

if [[ ! -d "$COREAI_MODELS_DIR/.git" ]]; then
    echo "==> cloning apple/coreai-models into $COREAI_MODELS_DIR"
    git clone --filter=blob:none https://github.com/apple/coreai-models "$COREAI_MODELS_DIR"
fi
if ! git -C "$COREAI_MODELS_DIR" cat-file -e "$COREAI_MODELS_REV^{commit}" 2>/dev/null; then
    git -C "$COREAI_MODELS_DIR" fetch --quiet origin
fi
git -C "$COREAI_MODELS_DIR" checkout --quiet "$COREAI_MODELS_REV"
echo "==> coreai-models @ $COREAI_MODELS_REV"

# A caller's activated virtualenv (e.g. this repo's .venv) must not leak into coreai-models' own
# uv-managed environment.
unset VIRTUAL_ENV
cd "$COREAI_MODELS_DIR"
uv sync --quiet

export_args=("$model" --platform macOS --compression "$compression" --output-dir "$OUT_ROOT" --output-name "$name")
[[ -n "$max_context" ]] && export_args+=(--max-context-length "$max_context")
[[ $overwrite -eq 1 ]] && export_args+=(--overwrite)

uv run coreai.llm.export "${export_args[@]}" --dry-run
[[ $dry_run -eq 1 ]] && exit 0

if [[ -f "$bundle/metadata.json" && $overwrite -eq 0 ]]; then
    # An existing finished bundle is only reused for --aot; otherwise re-exporting needs --overwrite.
    if [[ $aot -eq 0 ]]; then
        echo "bundle already exists: $bundle (pass --overwrite to replace it)" >&2
        exit 1
    fi
    echo "==> bundle exists; skipping export (pass --overwrite to re-export)"
else
    mkdir -p "$OUT_ROOT"
    echo "==> exporting $model ($compression) -> $bundle"
    start=$(date +%s)
    uv run coreai.llm.export "${export_args[@]}"
    echo "==> export finished in $(( $(date +%s) - start ))s"
fi

if [[ $aot -eq 1 ]]; then
    arch=$(printf 'import CoreAI\nprint(AIModel.deviceArchitectureName)\n' | xcrun swift - 2>/dev/null | tail -1)
    [[ -n "$arch" ]] || { echo "could not determine this Mac's Core AI architecture" >&2; exit 1; }
    compiled="$name.$arch.aimodelc"
    echo "==> AOT-compiling for $arch -> $compiled"
    rm -rf "${bundle:?}/$compiled"
    xcrun coreai-build compile "$bundle/$name.aimodel" --platform macOS --architecture "$arch" \
        --output "$bundle/$compiled"
    # models/README.md: after compiling, point metadata.json's asset at the compiled filename. The
    # source .aimodel stays so the bundle can be recompiled for another architecture.
    python3 - "$bundle/metadata.json" "$compiled" "$arch" <<'PY'
import json, sys
path, compiled, arch = sys.argv[1:]
with open(path) as f:
    meta = json.load(f)
meta["assets"]["main"] = compiled
meta.setdefault("compilation", {})["targets"] = [arch]
with open(path, "w") as f:
    json.dump(meta, f, indent=2)
PY
fi

echo
echo "Bundle ready: $bundle"
du -sh "$bundle"
echo "Smoke test:"
echo "  (cd \"$COREAI_MODELS_DIR\" && swift run -c release llm-runner --model \"$bundle\" --prompt \"Hello\")"
