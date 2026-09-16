#!/bin/bash
# Runs all week 5 experiments for ONE model, back to back, and saves
# everything under results/ with the standard naming:
#   results/exp3_task_energy/<model>/
#   results/exp2_decode_strat/out<budget>/<model>/
#   results/exp1_scaling/<model>/
#   results/logs/<model>_<timestamp>.log      (full console output)
#   results/<experiment>/all_models.csv       (refreshed at the end)
#
# Shortest experiment first, so problems show up early.
# Rerunning after an interruption picks up where it left off: finished
# experiments (they contain a COMPLETE file) are skipped, and a half-finished
# one is started again from scratch, overwriting its partial results.
#
# Usage:       ./run_model.sh <model-key>
# Smoke test:  ./run_model.sh <model-key> --smoke     (1 run each, tagged _smoke)
# Any env options (RUNS, COOLDOWN, THREADS...) pass through to every experiment.

source "$(dirname "$0")/common.sh"

KEY=${1:?"Usage: ./run_model.sh <model-key> [--smoke]   (keys: $(list_model_keys | tr '\n' ' '))"}
MODE=${2:-}
require_model "$KEY"

TAG=""
if [ "$MODE" = "--smoke" ]; then
  export TEST_MODE=1
  TAG=smoke
fi

mkdir -p "$RESULTS_DIR/logs"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="$RESULTS_DIR/logs/${MODEL_KEY}${TAG:+_$TAG}_${STAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== run_model: $MODEL_KEY ${TAG:+($TAG) }started $(date -Iseconds) ==="
echo "log: $LOG"

declare -a DONE SKIPPED FAILED
run_exp() {
  local name=$1 dir=$2
  shift 2
  local force=0
  if [ -e "$dir/COMPLETE" ]; then
    echo; echo ">>> $name: already complete in $dir, skipping"
    SKIPPED+=("$name")
    return
  elif [ -e "$dir/sweep_results.csv" ]; then
    echo; echo ">>> $name: found an unfinished run in $dir, restarting it"
    force=1
  fi
  echo; echo ">>> $name  ($(date +%H:%M:%S))"
  if FORCE=$force "$SCRIPT_DIR/$@"; then DONE+=("$name"); else FAILED+=("$name"); fi
}

SUFFIX=${TAG:+_$TAG}
if [ "$IS_REASONING" = "1" ]; then BUDGET=2048; else BUDGET=256; fi

run_exp exp3_task_energy  "$RESULTS_DIR/exp3_task_energy/${MODEL_KEY}${SUFFIX}" \
  exp3_task_energy.sh "$MODEL_KEY" $TAG
run_exp exp2_decode_strat "$RESULTS_DIR/exp2_decode_strat/out${BUDGET}/${MODEL_KEY}${SUFFIX}" \
  exp2_decode_strat.sh "$MODEL_KEY" "$BUDGET" $TAG
run_exp exp1_scaling      "$RESULTS_DIR/exp1_scaling/${MODEL_KEY}${SUFFIX}" \
  exp1_scaling.sh "$MODEL_KEY" $TAG

if [ -z "$TAG" ]; then
  echo; echo ">>> combining results across models"
  for e in exp1_scaling exp2_decode_strat exp3_task_energy; do
    [ -d "$RESULTS_DIR/$e" ] && "$SCRIPT_DIR/combine_results.sh" "$e"
  done
fi

echo
echo "=== run_model: $MODEL_KEY finished $(date -Iseconds) ==="
echo "done:    ${DONE[*]:-none}"
echo "skipped: ${SKIPPED[*]:-none}"
echo "failed:  ${FAILED[*]:-none}"
echo "log:     $LOG"
[ ${#FAILED[@]} -eq 0 ]
