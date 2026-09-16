#!/bin/bash
# Experiment 3 (week 5, new): energy per completed task.
# Bare task prompt (no padding), generous token budget, the model stops
# when it decides it's done. Measures what one coding request actually
# costs, including any reasoning, and whether the code works. This is the
# comparison that makes the reasoning model meaningful.
#
# Usage:        ./exp3_task_energy.sh <model-key> [tag]
# Smoke test:   TEST_MODE=1 ./exp3_task_energy.sh <model-key> smoke
# Options (env): RUNS=5  COOLDOWN=8  THREADS=<n>  FORCE=1
#                MAX_TOKENS  default 1024 (4096 for the reasoning model)
#                TASK_SAMPLING  default "--temp 0.6 --top-p 0.95 --top-k 0 --min-p 0.0"
#                  (same for every model; 0.6/0.95 is DeepSeek's recommended
#                   setting for R1, and greedy tends to make R1 loop)
# Results: results/exp3_task_energy/<model-key>[_<tag>]/

set -e
source "$(dirname "$0")/common.sh"

KEY=${1:?"Usage: ./exp3_task_energy.sh <model-key> [tag]"}
TAG=${2:-}
require_model "$KEY"
prepare_exp_dir "$RESULTS_DIR/exp3_task_energy/${MODEL_KEY}${TAG:+_$TAG}"

if [ "$IS_REASONING" = "1" ]; then DEFAULT_MAX=4096; else DEFAULT_MAX=1024; fi
MAX_TOKENS=${MAX_TOKENS:-$DEFAULT_MAX}
CTX=$(( MAX_TOKENS + 1024 ))
read -r -a SAMPLING <<< "${TASK_SAMPLING:---temp 0.6 --top-p 0.95 --top-k 0 --min-p 0.0}"
[ "${TEST_MODE:-0}" = "1" ] && RUNS=1

echo "model,run,elapsed_s,energy_uj,cpu_freq_khz" > "$TS_OUT"
echo "model,is_reasoning,max_tokens,input_tokens_actual,output_tokens_actual,think_tokens,answer_tokens,hit_budget,has_code,syntax_ok,passes_tests,prefill_tokens_per_sec,decode_tokens_per_sec,cpu_freq_khz,timestamp,run,energy_joules,wall_seconds,run_ok" > "$OUT"
write_meta "experiment: exp3_task_energy" "prompt: $CORE_TASK" "max_tokens: $MAX_TOKENS" "ctx: $CTX" "sampling: ${SAMPLING[*]}"

prompt=$(make_prompt 0)
input_actual=$(token_count "$prompt")

echo "=== exp3_task_energy: $MODEL_KEY max_tokens=$MAX_TOKENS -> $EXP_DIR ==="
for run in $(seq 1 "$RUNS"); do
  log="$RAW_DIR/task_run${run}.log"
  echo "[$run/$RUNS] $MODEL_KEY"
  sleep "$COOLDOWN"
  ts=$(date -Iseconds); freq=$(read_cpu_freq)
  e0=$(read_energy); t0=$(date +%s.%N)
  run_with_timeseries "$log" "$MODEL_KEY,$run" \
    -m "$MODEL_PATH" -p "$prompt" -n "$MAX_TOKENS" -c "$CTX" -st --no-display-prompt \
    "${SAMPLING[@]}" "${THREAD_FLAGS[@]}"
  t1=$(date +%s.%N); e1=$(read_energy)

  text=$(extract_generated_text "$log")
  printf '%s\n' "$text" > "${log%.log}.txt"
  output_actual=$(token_count "$text")
  think_tokens=$(token_count "$(printf '%s' "$text" | split_text think)")
  answer_tokens=$(token_count "$(printf '%s' "$text" | split_text answer)")
  hit_budget=0
  [[ "$output_actual" =~ ^[0-9]+$ ]] && [ "$output_actual" -ge $(( MAX_TOKENS * 95 / 100 )) ] && hit_budget=1
  checks=$(printf '%s' "$text" | python3 "$SCRIPT_DIR/check_code.py")
  tput=$(extract_throughput "$log")
  energy=$(energy_delta_j "$e0" "$e1")
  wall=$(echo "scale=4; $t1 - $t0" | bc)
  echo "$MODEL_KEY,$IS_REASONING,$MAX_TOKENS,$input_actual,$output_actual,$think_tokens,$answer_tokens,$hit_budget,$checks,$tput,$freq,$ts,$run,$energy,$wall,$RUN_OK" >> "$OUT"
  echo "      ${energy}J ${wall}s out=$output_actual (think=$think_tokens) code(has,syntax,pass)=$checks hit_budget=$hit_budget"
done
date -Iseconds > "$EXP_DIR/COMPLETE"   # marks a finished sweep (run_model.sh checks this)
echo "Done: $OUT"
