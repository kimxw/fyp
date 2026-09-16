#!/bin/bash
# Experiment 2 (week 5): decoding strategy comparison, one model per call.
# Same four strategies as week 3 (greedy / temperature / top_p / top_k),
# fixed input (512 requested), fixed output budget.
#
# Usage:        ./exp2_decode_strat.sh <model-key> [output-budget] [tag]
#               output-budget defaults to 256 (2048 for the reasoning model)
# Smoke test:   TEST_MODE=1 ./exp2_decode_strat.sh <model-key> 256 smoke
# Options (env): RUNS=5  COOLDOWN=8  THREADS=<n>  FORCE=1
# Results: results/exp2_decode_strat/out<budget>/<model-key>[_<tag>]/
#
# Fixes vs week 3: contains_return is now actually written (the week 3
# long-budget CSV header had it but rows didn't, shifting the columns).

set -e
source "$(dirname "$0")/common.sh"

KEY=${1:?"Usage: ./exp2_decode_strat.sh <model-key> [output-budget] [tag]"}
require_model "$KEY"
if [ "$IS_REASONING" = "1" ]; then DEFAULT_BUDGET=2048; else DEFAULT_BUDGET=256; fi
BUDGET=${2:-$DEFAULT_BUDGET}
TAG=${3:-}
prepare_exp_dir "$RESULTS_DIR/exp2_decode_strat/out${BUDGET}/${MODEL_KEY}${TAG:+_$TAG}"

FIXED_INPUT=512
CTX=$(( BUDGET + 1024 > 4096 ? BUDGET + 1024 : 4096 ))

# Each strategy disables the samplers it isn't testing (llama.cpp's defaults
# otherwise leave top_k=40 / top_p=0.95 / min_p active in the background).
declare -A STRATEGIES=(
  [greedy]="--temp 0"
  [temperature]="--temp 0.8 --top-k 0 --top-p 1.0 --min-p 0.0"
  [top_p]="--temp 0.8 --top-k 0 --top-p 0.9 --min-p 0.0"
  [top_k]="--temp 0.8 --top-k 40 --top-p 1.0 --min-p 0.0"
)
if [ "${TEST_MODE:-0}" = "1" ]; then
  RUNS=1; ORDER=(greedy)
else
  ORDER=(greedy temperature top_p top_k)
fi

echo "model,strategy,run,elapsed_s,energy_uj,cpu_freq_khz" > "$TS_OUT"
echo "model,strategy,output_budget,input_tokens_actual,output_tokens_actual,think_tokens,answer_tokens,hit_budget,contains_return,has_code,syntax_ok,passes_tests,prefill_tokens_per_sec,decode_tokens_per_sec,cpu_freq_khz,timestamp,run,energy_joules,wall_seconds,run_ok" > "$OUT"
write_meta "experiment: exp2_decode_strat" "input_requested: $FIXED_INPUT" "output_budget: $BUDGET" "ctx: $CTX" \
  "strategies: $(for s in "${ORDER[@]}"; do printf '%s=[%s] ' "$s" "${STRATEGIES[$s]}"; done)"

prompt=$(make_prompt $(( FIXED_INPUT * 3 / 4 )))
input_actual=$(token_count "$prompt")
TOTAL=$(( ${#ORDER[@]} * RUNS ))
COUNT=0

echo "=== exp2_decode_strat: $MODEL_KEY budget=$BUDGET -> $EXP_DIR ==="
for strat in "${ORDER[@]}"; do
  read -r -a sflags <<< "${STRATEGIES[$strat]}"
  for run in $(seq 1 "$RUNS"); do
    COUNT=$((COUNT + 1))
    log="$RAW_DIR/${strat}_run${run}.log"
    echo "[$COUNT/$TOTAL] $MODEL_KEY strategy=$strat run=$run/$RUNS"
    sleep "$COOLDOWN"
    ts=$(date -Iseconds); freq=$(read_cpu_freq)
    e0=$(read_energy); t0=$(date +%s.%N)
    run_with_timeseries "$log" "$MODEL_KEY,$strat,$run" \
      -m "$MODEL_PATH" -p "$prompt" -n "$BUDGET" -c "$CTX" -st --no-display-prompt \
      "${sflags[@]}" "${THREAD_FLAGS[@]}"
    t1=$(date +%s.%N); e1=$(read_energy)

    text=$(extract_generated_text "$log")
    printf '%s\n' "$text" > "${log%.log}.txt"
    output_actual=$(token_count "$text")
    think_tokens=$(token_count "$(printf '%s' "$text" | split_text think)")
    answer_tokens=$(token_count "$(printf '%s' "$text" | split_text answer)")
    hit_budget=0
    [[ "$output_actual" =~ ^[0-9]+$ ]] && [ "$output_actual" -ge $(( BUDGET * 95 / 100 )) ] && hit_budget=1
    contains_return=0
    printf '%s' "$text" | split_text answer | grep -q "return" && contains_return=1
    checks=$(printf '%s' "$text" | python3 "$SCRIPT_DIR/check_code.py")
    tput=$(extract_throughput "$log")
    energy=$(energy_delta_j "$e0" "$e1")
    wall=$(echo "scale=4; $t1 - $t0" | bc)
    echo "$MODEL_KEY,$strat,$BUDGET,$input_actual,$output_actual,$think_tokens,$answer_tokens,$hit_budget,$contains_return,$checks,$tput,$freq,$ts,$run,$energy,$wall,$RUN_OK" >> "$OUT"
    echo "      ${energy}J ${wall}s out=$output_actual (think=$think_tokens) code(has,syntax,pass)=$checks"
  done
done
date -Iseconds > "$EXP_DIR/COMPLETE"   # marks a finished sweep (run_model.sh checks this)
echo "Done: $OUT"
