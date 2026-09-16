#!/bin/bash
# Experiment 2: Decoding strategy comparison (greedy / temperature / top-p / top-k)
# at FIXED input and output length. Tests Fernandez et al.'s decoding-strategy
# claim (Figure 3) on CPU. Usage: ./sweep_decode_strat.sh <experiment-name>
# Usage (smoke test): TEST_MODE=1 ./sweep_decode_strat.sh <experiment-name>

set -e

BASE=~/fyp/fernandez-cpu-followup
EXP_NAME=${1:?"Usage: ./sweep_decode_strat.sh <experiment-name>"}
EXP_DIR=$BASE/results/$EXP_NAME
RAW_DIR=$EXP_DIR/raw

MODEL=$BASE/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
BIN=$BASE/llama.cpp/build/bin/llama-cli
TOKENIZE_BIN=$BASE/llama.cpp/build/bin/llama-tokenize
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
OUT=$EXP_DIR/sweep_results.csv
RUNS=3
COOLDOWN=8

# Fixed input/output length for all strategies — only the sampling flags vary.
FIXED_INPUT=512
FIXED_OUTPUT=128

mkdir -p "$RAW_DIR"
TS_OUT=$EXP_DIR/timeseries.csv
echo "strategy,elapsed_s,energy_uj,cpu_freq_khz" > "$TS_OUT"
echo "strategy,input_tokens_actual,output_tokens_actual,prefill_tokens_per_sec,decode_tokens_per_sec,cpu_freq_khz,timestamp,run,energy_joules,wall_seconds" > "$OUT"

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

token_count() {
  local text=$1
  local raw=$(echo -n "$text" | "$TOKENIZE_BIN" -m "$MODEL" --stdin --show-count 2>/dev/null \
    | grep -oP 'Total number of tokens: \K[0-9]+' | tail -1)
  if [ -n "$raw" ] && [ "$raw" -gt 0 ]; then echo $((raw - 1)); else echo ""; fi
}

strip_ansi() { sed -r 's/\x1B(\[[0-9;][a-zA-Z]|\][^\x07](\x07|\x1B\\))//g'; }

extract_generated_text() {
  strip_ansi < "$1" | awk '/^> /{flag=1; next} /^\[ Prompt:/{flag=0} flag'
}

extract_throughput() {
  local clean=$(strip_ansi < "$1")
  local prefill=$(echo "$clean" | grep -oP '\[ Prompt: \K[0-9.]+' | tail -1)
  local decode=$(echo "$clean" | grep -oP 'Generation: \K[0-9.]+' | tail -1)
  echo "${prefill:-NA},${decode:-NA}"
}

run_with_timeseries() {
  local logfile=$1
  local strategy=$2
  shift 2
  local cmd
  printf -v cmd '%q ' "$BIN" "$@"
  script -qec "$cmd" "$logfile" &
  local pid=$!
  local t0=$(date +%s.%N)
  local elapsed_display=0
  while kill -0 $pid 2>/dev/null; do
    local now=$(date +%s.%N)
    local elapsed=$(echo "scale=3; $now - $t0" | bc)
    echo "$strategy,$elapsed,$(read_energy),$(read_cpu_freq)" >> "$TS_OUT"
    printf "\r      ...running (elapsed %ds)" $elapsed_display
    sleep 1
    elapsed_display=$((elapsed_display + 1))
  done
  wait $pid
  printf "\r      done (elapsed ~%ds)          \n" $elapsed_display
}

# Strategy definitions: name -> extra llama-cli flags
# NOTE: llama.cpp's default sampler chain has top_k=40 and top_p=0.95 active
# in the background regardless of other settings. Each condition below
# explicitly disables the ones it isn't testing (top-k 0 = disabled,
# top-p 1.0 = disabled, min-p 0.0 = disabled) so each strategy is genuinely
# isolated rather than silently layered on top of the defaults.
declare -A STRATEGIES=(
  ["greedy"]="--temp 0"
  ["temperature"]="--temp 0.8 --top-k 0 --top-p 1.0 --min-p 0.0"
  ["top_p"]="--temp 0.8 --top-k 0 --top-p 0.9 --min-p 0.0"
  ["top_k"]="--temp 0.8 --top-k 40 --top-p 1.0 --min-p 0.0"
)

if [ "${TEST_MODE:-0}" = "1" ]; then
  echo "* TEST_MODE=1 — smoke test: only 'greedy' strategy, 1 run *"
  RUNS=1
  STRATEGY_ORDER=(greedy)
else
  STRATEGY_ORDER=(greedy temperature top_p top_k)
fi

TOTAL=$(( ${#STRATEGY_ORDER[@]} * RUNS ))
COUNT=0

target_words=$(( FIXED_INPUT * 3 / 4 ))
prompt=$(make_prompt $target_words)
input_actual=$(token_count "$prompt")

for strat in "${STRATEGY_ORDER[@]}"; do
  extra_flags=${STRATEGIES[$strat]}
  for run in $(seq 1 $RUNS); do
    COUNT=$((COUNT + 1))
    logfile="$RAW_DIR/${strat}_run${run}.log"
    echo "[$COUNT / $TOTAL] strategy=$strat run=$run/$RUNS"
    sleep $COOLDOWN
    ts_before=$(date -Iseconds)
    freq_before=$(read_cpu_freq)
    e_before=$(read_energy)
    t_before=$(date +%s.%N)
    run_with_timeseries "$logfile" "$strat" -m "$MODEL" -p "$prompt" -n $FIXED_OUTPUT -st --no-display-prompt $extra_flags
    t_after=$(date +%s.%N)
    e_after=$(read_energy)

    generated_text=$(extract_generated_text "$logfile")
    output_actual=$(token_count "$generated_text")
    throughput=$(extract_throughput "$logfile")

    energy_j=$(echo "scale=4; ($e_after - $e_before) / 1000000" | bc)
    wall_s=$(echo "scale=4; $t_after - $t_before" | bc)
    echo "$strat,${input_actual:-NA},${output_actual:-NA},$throughput,$freq_before,$ts_before,$run,$energy_j,$wall_s" >> "$OUT"
    echo "      energy=${energy_j}J time=${wall_s}s actual_tokens(in,out)=${input_actual:-NA},${output_actual:-NA}"
  done
done

echo ""
echo "Done. Results in $OUT"
