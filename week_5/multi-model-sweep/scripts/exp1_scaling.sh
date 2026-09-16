#!/bin/bash
# Experiment 1 (week 5): prefill/decode energy scaling, one model per call.
# Same design as week 3's sweep2.sh, with more lengths and 5 repeats.
#
#   Input sweep : input length varies, output fixed at 64
#   Output sweep: output length varies, input fixed at 512
#
# Usage:        ./exp1_scaling.sh <model-key> [tag]
# Smoke test:   TEST_MODE=1 ./exp1_scaling.sh <model-key> smoke
# Options (env): RUNS=5  COOLDOWN=8  THREADS=<n>  FORCE=1
#                IGNORE_EOS=1   force exactly N output tokens (default off, as in week 3)
#                INPUT_LENGTHS="128 256 ..."  OUTPUT_LENGTHS="8 16 ..."
# Results: results/exp1_scaling/<model-key>[_<tag>]/

set -e
source "$(dirname "$0")/common.sh"

KEY=${1:?"Usage: ./exp1_scaling.sh <model-key> [tag]   (keys: $(list_model_keys | tr '\n' ' '))"}
TAG=${2:-}
require_model "$KEY"
prepare_exp_dir "$RESULTS_DIR/exp1_scaling/${MODEL_KEY}${TAG:+_$TAG}"

FIXED_OUTPUT=64
FIXED_INPUT=512
CTX=4096
if [ "${TEST_MODE:-0}" = "1" ]; then
  RUNS=1
  INPUTS=(128)
  OUTPUTS=(8)
else
  read -r -a INPUTS <<< "${INPUT_LENGTHS:-128 256 384 512 768 1024 1536 2048}"
  read -r -a OUTPUTS <<< "${OUTPUT_LENGTHS:-8 16 32 64 128 256 384 512}"
fi
EOS_FLAGS=()
[ "${IGNORE_EOS:-0}" = "1" ] && EOS_FLAGS=(--ignore-eos)

echo "model,sweep_type,input_tokens_requested,output_tokens_requested,run,elapsed_s,energy_uj,cpu_freq_khz" > "$TS_OUT"
echo "model,sweep_type,input_tokens_requested,output_tokens_requested,input_tokens_actual,output_tokens_actual,prefill_tokens_per_sec,decode_tokens_per_sec,cpu_freq_khz,timestamp,run,energy_joules,wall_seconds,run_ok" > "$OUT"
write_meta "experiment: exp1_scaling" "inputs (output=$FIXED_OUTPUT): ${INPUTS[*]}" \
  "outputs (input=$FIXED_INPUT): ${OUTPUTS[*]}" "ignore_eos: ${IGNORE_EOS:-0}" "ctx: $CTX"

TOTAL=$(( (${#INPUTS[@]} + ${#OUTPUTS[@]}) * RUNS ))
COUNT=0

run_point() {
  local sweep_type=$1 in_req=$2 out_req=$3
  local prompt input_actual
  prompt=$(make_prompt $(( in_req * 3 / 4 )))
  input_actual=$(token_count "$prompt")
  for run in $(seq 1 "$RUNS"); do
    COUNT=$((COUNT + 1))
    local log="$RAW_DIR/${sweep_type}_in${in_req}_out${out_req}_run${run}.log"
    echo "[$COUNT/$TOTAL] $MODEL_KEY $sweep_type in=$in_req out=$out_req run=$run/$RUNS"
    sleep "$COOLDOWN"
    local ts freq e0 t0 e1 t1
    ts=$(date -Iseconds); freq=$(read_cpu_freq)
    e0=$(read_energy); t0=$(date +%s.%N)
    run_with_timeseries "$log" "$MODEL_KEY,$sweep_type,$in_req,$out_req,$run" \
      -m "$MODEL_PATH" -p "$prompt" -n "$out_req" -c $CTX -st --no-display-prompt \
      "${EOS_FLAGS[@]}" "${THREAD_FLAGS[@]}"
    t1=$(date +%s.%N); e1=$(read_energy)

    local text output_actual tput energy wall
    text=$(extract_generated_text "$log")
    printf '%s\n' "$text" > "${log%.log}.txt"
    output_actual=$(token_count "$text")
    tput=$(extract_throughput "$log")
    energy=$(energy_delta_j "$e0" "$e1")
    wall=$(echo "scale=4; $t1 - $t0" | bc)
    echo "$MODEL_KEY,$sweep_type,$in_req,$out_req,$input_actual,$output_actual,$tput,$freq,$ts,$run,$energy,$wall,$RUN_OK" >> "$OUT"
    echo "      ${energy}J ${wall}s tokens(in,out)=$input_actual,$output_actual tput=$tput"
  done
}

echo "=== exp1_scaling: $MODEL_KEY -> $EXP_DIR ==="
for n in "${INPUTS[@]}"; do run_point input_sweep "$n" $FIXED_OUTPUT; done
for n in "${OUTPUTS[@]}"; do run_point output_sweep $FIXED_INPUT "$n"; done
date -Iseconds > "$EXP_DIR/COMPLETE"   # marks a finished sweep (run_model.sh checks this)
echo "Done: $OUT"
