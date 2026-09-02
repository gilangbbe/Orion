#!/bin/zsh
set -e
cd "/Users/biru/Work/LearningDevelopment/Orion/Agent Feasibility Study"
PY=/Users/biru/Work/LearningDevelopment/Orion/.venv/bin/python
export PYTHONPATH=harness
export HF_HUB_DISABLE_PROGRESS_BARS=1
echo "### RUN start $(date)"
$PY -m orion_eval.cli run --model seed
echo "### GRADE start $(date)"
$PY -m orion_eval.cli grade --judge mlx:mlx-community/Qwen3-8B-4bit
echo "### LEADERBOARD start $(date)"
$PY -m orion_eval.cli leaderboard
echo "### DONE $(date)"
