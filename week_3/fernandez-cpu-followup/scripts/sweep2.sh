#!/bin/bash
# Generic energy sweep runner for fernandez-cpu-followup experiments.
# Usage: ./sweep.sh <experiment-name>
# Usage (smoke test): TEST_MODE=1 ./sweep.sh <experiment-name>

set -e

BASE=~/fyp/fernandez-cpu-followup
EXP_NAME=${1:?"Usage: ./sweep.sh <experiment-name>, e.g. exp1-prefill-decode-scaling"}
EXP_DIR=$BASE/results/$EXP_NAME
RAW_DIR=$EXP_DIR/raw

MODEL=$BASE/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
BIN=$BASE/llama.cpp/build/bin/llama-cli
TOKENIZE_BIN=$BASE/llama.cpp/build/bin/llama-tokenize
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
OUT=$EXP_DIR/sweep_results.csv
RUNS=3
COOLDOWN=8

mkdir -p "$RAW_DIR"
TS_OUT=$EXP_DIR/timeseries.csv
echo "sweep_type,input_tokens_requested,output_tokens_requested,run,elapsed_s,energy_uj,cpu_freq_khz" > "$TS_OUT"
# NOTE: input_tokens_actual/output_tokens_actual are RAW CONTENT token
# counts via llama-tokenize (BOS token subtracted), NOT the full
# chat-template-wrapped count the model actually processes internally
# (which adds a roughly constant ~34-token system/role-header overhead on
# top of this). This is a deliberate simplification — replicating the
# exact template (which embeds today's date) is fragile, and since the
# overhead is ~constant across runs it doesn't distort the scaling trend,
# only the absolute token count. Re-tokenizing detokenized generated text
# can also differ from the model's true internal generation count by a
# small handful of tokens — a known BPE roundtrip quirk, not a script bug.
# load_time_ms is NOT available in this llama.cpp build without -v verbose
# logging, which itself adds enough I/O overhead to bias the energy
# measurement, so it has been dropped rather than captured inaccurately.
echo "sweep_type,input_tokens_requested,output_tokens_requested,input_tokens_actual,output_tokens_actual,prefill_tokens_per_sec,decode_tokens_per_sec,cpu_freq_khz,timestamp,run,energy_joules,wall_seconds" > "$OUT"

# The actual task is IDENTICAL at every input length — only surrounding
# context/background grows. CORE_TASK is always the literal instruction;
# CONTEXT_LAYERS are non-task-altering background padding.
CORE_TASK="Write a function to sort a list of numbers using bubble sort."
CONTEXT_LAYERS=(
  "Bubble sort is one of the simplest sorting algorithms taught in introductory computer science courses."
  "It works by repeatedly stepping through a list, comparing each pair of adjacent elements, and swapping them if they are in the wrong order."
  "This process is repeated until no more swaps are needed, at which point the list is fully sorted."
  "The algorithm gets its name because smaller elements slowly bubble toward the front of the list with each pass, similar to how bubbles rise to the surface of water."
  "Despite its simplicity, bubble sort is generally considered inefficient for large datasets compared to algorithms like quicksort or mergesort."
  "It is still commonly used as a teaching tool because its logic is easy to trace by hand and easy to visualize step by step."
  "Many textbooks introduce bubble sort before more advanced algorithms specifically because its behavior is so straightforward to reason about."
  "Some implementations include an early-exit optimization that stops the algorithm once a full pass completes with no swaps, since that means the list is already sorted."
)

make_prompt() {
  # $1 = target word count (approx tokens/1.3, rough word-to-token ratio)
  python3 -c "
core = '''$CORE_TASK'''
layers = '''$(printf '%s\n' "${CONTEXT_LAYERS[@]}")'''.strip().split(chr(10))
target = $1
core_words = core.split()
pad_target = max(0, target - len(core_words))
pad_words = []
i = 0
while len(pad_words) < pad_target:
    pad_words += layers[i % len(layers)].split()
    i += 1
pad_words = pad_words[:pad_target]
print(' '.join(pad_words + core_words))
"
}

read_energy() { cat $RAPL; }
read_cpu_freq() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "NA"; }

# Real, build-independent token count via the dedicated tokenizer tool.
# Subtracts 1 to remove the BOS token llama-tokenize always auto-prepends.
token_count() {
  local text=$1
  local raw=$(echo -n "$text" | "$TOKENIZE_BIN" -m "$MODEL" --stdin --show-count 2>/dev/null \
    | grep -oP 'Total number of tokens: \K[0-9]+' | tail -1)
  if [ -n "$raw" ] && [ "$raw" -gt 0 ]; then
    echo $((raw - 1))
  else
    echo ""
  fi
}

# llama-cli writes its live/interactive display directly to the tty,
# bypassing stdout even when redirected. script allocates a
# pseudo-terminal so it can actually capture what's written.
strip_ansi() {
  sed -r 's/\x1B(\[[0-9;][a-zA-Z]|\][^\x07](\x07|\x1B\\))//g'
}

extract_generated_text() {
  local logfile=$1
  strip_ansi < "$logfile" | awk '/^> /{flag=1; next} /^\[ Prompt:/{flag=0} flag'
}

extract_throughput() {
  local logfile=$1
  local clean=$(strip_ansi < "$logfile")
  local prefill=$(echo "$clean" | grep -oP '\[ Prompt: \K[0-9.]+' | tail -1)
  local decode=$(echo "$clean" | grep -oP 'Generation: \K[0-9.]+' | tail -1)
  echo "${prefill:-NA},${decode:-NA}"
}

# Runs llama-cli inside script in the background. While it runs, this
# ALSO samples RAPL energy + CPU frequency roughly once a second, appending
# tagged rows to the experiment's single consolidated timeseries.csv (one
# file for the whole sweep, not one per run), so we can see what's
# happening DURING generation and later plot power/frequency over time.
# This sampler adds a small amount of its own CPU/energy overhead —
# documented as a known, minor bias, not eliminated.
run_with_timeseries() {
  local logfile=$1
  local sweep_type=$2
  local input_toks=$3
  local output_toks=$4
  local run=$5
  shift 5
  local cmd
  printf -v cmd '%q ' "$BIN" "$@"
  script -qec "$cmd" "$logfile" &
  local pid=$!

  local t0=$(date +%s.%N)
  local elapsed_display=0
  while kill -0 $pid 2>/dev/null; do
    local now=$(date +%s.%N)
    local elapsed=$(echo "scale=3; $now - $t0" | bc)
    echo "$sweep_type,$input_toks,$output_toks,$run,$elapsed,$(read_energy),$(read_cpu_freq)" >> "$TS_OUT"
    printf "\r      ...running (elapsed %ds)" $elapsed_display
    sleep 1
    elapsed_display=$((elapsed_display + 1))
  done
  wait $pid
  printf "\r      done (elapsed ~%ds)          \n" $elapsed_display
}

run_once() {
  local input_toks=$1
  local output_toks=$2
  local sweep_type=$3
  local target_words=$(( input_toks * 3 / 4 ))
  local prompt=$(make_prompt $target_words)
  local input_actual=$(token_count "$prompt")

  for run in $(seq 1 $RUNS); do
    COUNT=$((COUNT + 1))
    local logfile="$RAW_DIR/${sweep_type}_in${input_toks}_out${output_toks}_run${run}.log"
    echo "[$COUNT / $TOTAL] $sweep_type input=$input_toks output=$output_toks run=$run/$RUNS"
    sleep $COOLDOWN
    local ts_before=$(date -Iseconds)
    local freq_before=$(read_cpu_freq)
    e_before=$(read_energy)
    t_before=$(date +%s.%N)
    run_with_timeseries "$logfile" "$sweep_type" "$input_toks" "$output_toks" "$run" -m "$MODEL" -p "$prompt" -n $output_toks -st --no-display-prompt
    t_after=$(date +%s.%N)
    e_after=$(read_energy)

    local generated_text=$(extract_generated_text "$logfile")
    local output_actual=$(token_count "$generated_text")
    local throughput=$(extract_throughput "$logfile")

    energy_j=$(echo "scale=4; ($e_after - $e_before) / 1000000" | bc)
    wall_s=$(echo "scale=4; $t_after - $t_before" | bc)
    echo "$sweep_type,$input_toks,$output_toks,${input_actual:-NA},${output_actual:-NA},$throughput,$freq_before,$ts_before,$run,$energy_j,$wall_s" >> "$OUT"
    echo "      energy=${energy_j}J time=${wall_s}s actual_tokens(in,out)=${input_actual:-NA},${output_actual:-NA} throughput=${throughput}"
  done
}

echo "=== Running experiment: $EXP_NAME ==="
echo "Results will be written to: $OUT"
echo "Consolidated timeseries: $TS_OUT"
echo "Raw per-run logs in: $RAW_DIR"
echo ""

if [ "${TEST_MODE:-0}" = "1" ]; then
  echo "* TEST_MODE=1 — running a single minimal smoke test, not a real sweep *"
  RUNS=1
  INPUT_LENGTHS=(128)
  OUTPUT_LENGTHS=()
else
  # Expanded, log-spaced x-axis coverage for the real sweep, so the
  # sub-linear -> linear transition is visible as an actual curve shape
  # rather than inferred from just 2-3 points.
  INPUT_LENGTHS=(128 256 512 1024 2048)
  OUTPUT_LENGTHS=(8 32 64 128 256 512)
fi
TOTAL=$(( (${#INPUT_LENGTHS[@]} + ${#OUTPUT_LENGTHS[@]}) * RUNS ))
COUNT=0

for input_len in "${INPUT_LENGTHS[@]}"; do
  run_once $input_len 64 "input_sweep"
done

for output_len in "${OUTPUT_LENGTHS[@]}"; do
  run_once 512 $output_len "output_sweep"
done

echo ""
echo "Done. Results in $OUT"
