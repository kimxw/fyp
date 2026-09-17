#!/bin/bash
# Shared config + helpers for week 5 sweeps. Sourced, not run directly.
#
# Paths can be overridden with environment variables. Defaults assume the
# Lenovo layout from week 3, where llama.cpp and the models already live:
#   ~/fyp/fernandez-cpu-followup/{llama.cpp,models}
#
# MACHINE: short label for the hardware the sweep runs on (letters, digits,
# . _ -). When set, results go to results_<MACHINE>/ instead of results/, so
# runs from different machines never mix. results/ (no label) holds the
# original Lenovo IdeaPad Flex 5 runs.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WEEK5_DIR=$(dirname "$SCRIPT_DIR")
MACHINE=${MACHINE:-}
if [ -n "$MACHINE" ]; then
  if ! [[ "$MACHINE" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: MACHINE='$MACHINE' may only contain letters, digits, . _ -" >&2
    exit 1
  fi
  RESULTS_DIR=${RESULTS_DIR:-$WEEK5_DIR/results_$MACHINE}
else
  RESULTS_DIR=${RESULTS_DIR:-$WEEK5_DIR/results}
fi
LLAMA_DIR=${LLAMA_DIR:-$HOME/fyp/fernandez-cpu-followup/llama.cpp}
MODELS_DIR=${MODELS_DIR:-$HOME/fyp/fernandez-cpu-followup/models}
BIN=$LLAMA_DIR/build/bin/llama-cli
TOKENIZE_BIN=$LLAMA_DIR/build/bin/llama-tokenize
RAPL=${RAPL:-/sys/class/powercap/intel-rapl:0/energy_uj}
RAPL_MAX=$(cat "$(dirname "$RAPL")/max_energy_range_uj" 2>/dev/null || echo 0)
RUNS=${RUNS:-5}
COOLDOWN=${COOLDOWN:-8}
# Optional: pin thread count (llama.cpp picks its own default if unset)
THREAD_FLAGS=()
[ -n "${THREADS:-}" ] && THREAD_FLAGS=(-t "$THREADS")

source "$SCRIPT_DIR/models.sh"

# Same task + padding as week 3, so results stay comparable. The task is
# identical at every input length; only the background context grows.
CORE_TASK="Write a function to sort a list of numbers using bubble sort."
CONTEXT_LAYERS="Bubble sort is one of the simplest sorting algorithms taught in introductory computer science courses.
It works by repeatedly stepping through a list, comparing each pair of adjacent elements, and swapping them if they are in the wrong order.
This process is repeated until no more swaps are needed, at which point the list is fully sorted.
The algorithm gets its name because smaller elements slowly bubble toward the front of the list with each pass, similar to how bubbles rise to the surface of water.
Despite its simplicity, bubble sort is generally considered inefficient for large datasets compared to algorithms like quicksort or mergesort.
It is still commonly used as a teaching tool because its logic is easy to trace by hand and easy to visualize step by step.
Many textbooks introduce bubble sort before more advanced algorithms specifically because its behavior is so straightforward to reason about.
Some implementations include an early-exit optimization that stops the algorithm once a full pass completes with no swaps, since that means the list is already sorted."

# make_prompt <target_word_count>   (0 = bare task, no padding)
make_prompt() {
  CORE="$CORE_TASK" LAYERS="$CONTEXT_LAYERS" TARGET="$1" python3 - <<'PY'
import os
core = os.environ["CORE"].split()
layers = os.environ["LAYERS"].strip().split("\n")
pad_target = max(0, int(os.environ["TARGET"]) - len(core))
pad, i = [], 0
while len(pad) < pad_target:
    pad += layers[i % len(layers)].split()
    i += 1
print(" ".join(pad[:pad_target] + core))
PY
}

read_energy() { cat "$RAPL"; }
read_cpu_freq() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "NA"; }

# energy_delta_j <before_uj> <after_uj>  -- handles the RAPL counter wrapping
# around, which becomes more likely with multi-minute 7B runs.
energy_delta_j() {
  python3 -c "
b, a, m = $1, $2, $RAPL_MAX
d = a - b
if d < 0 and m > 0: d += m
print(f'{d/1e6:.4f}')"
}

# Raw content token count via llama-tokenize, minus the auto-added BOS.
# Same simplification as week 3: excludes the chat-template overhead.
# Must be re-run per model because tokenizers differ between families.
token_count() {
  local text=$1 raw
  [ -z "$text" ] && { echo 0; return; }
  raw=$(printf '%s' "$text" | "$TOKENIZE_BIN" -m "$MODEL_PATH" --stdin --show-count 2>/dev/null \
    | grep -oP 'Total number of tokens: \K[0-9]+' | tail -1)
  if [ -n "$raw" ] && [ "$raw" -gt 0 ]; then echo $((raw - 1)); else echo "NA"; fi
}

# `script` records through a pseudo-terminal, so lines end in \r\n: drop the \r too.
strip_ansi() { sed -r 's/\x1B(\[[0-9;]*[a-zA-Z]|\][^\x07]*(\x07|\x1B\\))//g' | tr -d '\r'; }

extract_generated_text() {
  strip_ansi < "$1" | awk '/^> /{flag=1; next} /^\[ Prompt:/{flag=0} flag'
}

extract_throughput() {
  local clean prefill decode
  clean=$(strip_ansi < "$1")
  prefill=$(echo "$clean" | grep -oP '\[ Prompt: \K[0-9.]+' | tail -1)
  decode=$(echo "$clean" | grep -oP 'Generation: \K[0-9.]+' | tail -1)
  echo "${prefill:-NA},${decode:-NA}"
}

# Splits reasoning output. Prints the requested part: think | answer
split_text() {
  python3 "$SCRIPT_DIR/check_code.py" --part "$1"
}

# Runs llama-cli under `script` (it writes straight to the tty) while
# sampling RAPL + CPU frequency about once a second into $TS_OUT.
# run_with_timeseries <logfile> <csv-prefix-for-timeseries-rows> <llama args...>
# Sets RUN_OK=1/0 instead of killing the whole sweep on one failed run.
run_with_timeseries() {
  local logfile=$1 prefix=$2
  shift 2
  local cmd
  printf -v cmd '%q ' "$BIN" "$@"
  script -qec "$cmd" "$logfile" > /dev/null &
  local pid=$! t0 now elapsed secs=0
  t0=$(date +%s.%N)
  while kill -0 $pid 2>/dev/null; do
    now=$(date +%s.%N)
    elapsed=$(echo "scale=3; $now - $t0" | bc)
    echo "$prefix,$elapsed,$(read_energy),$(read_cpu_freq)" >> "$TS_OUT"
    printf "\r      ...running (%ds)" $secs
    sleep 1
    secs=$((secs + 1))
  done
  if wait $pid; then RUN_OK=1; else RUN_OK=0; fi
  printf "\r      done (~%ds, ok=%s)          \n" $secs $RUN_OK
}

# prepare_exp_dir <dir>  -- refuses to overwrite earlier results unless FORCE=1
prepare_exp_dir() {
  EXP_DIR=$1
  if [ -e "$EXP_DIR/sweep_results.csv" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "ERROR: $EXP_DIR already has results. Use a different tag, or FORCE=1 to overwrite." >&2
    exit 1
  fi
  RAW_DIR=$EXP_DIR/raw
  mkdir -p "$RAW_DIR"
  OUT=$EXP_DIR/sweep_results.csv
  TS_OUT=$EXP_DIR/timeseries.csv
}

# llama.cpp build identifier. Only trusts git if llama.cpp is its own repo
# (otherwise git walks up to an enclosing repo, e.g. ~/fyp, and reports that
# commit instead), and falls back to the binary's own --version output.
# Must match across machines for a fair hardware comparison.
llama_cpp_version() {
  if [ -e "$LLAMA_DIR/.git" ]; then
    git -C "$LLAMA_DIR" rev-parse --short HEAD 2>/dev/null && return
  fi
  "$BIN" --version 2>&1 | grep -m1 -i "version" || echo unknown
}

# Hardware facts readable without sudo (full details: record_hardware.sh)
hardware_summary() {
  local rdir cpu cores flags limits c name uw
  rdir=$(dirname "$RAPL")
  cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
  cores=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
  flags=$(grep -o -w -E 'avx2|avx_vnni|avx512f' /proc/cpuinfo 2>/dev/null | sort -u | tr '\n' ' ')
  limits=""
  for c in 0 1 2; do
    name=$(cat "$rdir/constraint_${c}_name" 2>/dev/null) || continue
    uw=$(cat "$rdir/constraint_${c}_power_limit_uw" 2>/dev/null || echo 0)
    limits+="$name=$(( uw / 1000000 ))W "
  done
  echo "machine: ${MACHINE:-lenovo-flex5-14iau7 (default results/)}"
  echo "cpu_model: ${cpu:-unknown}"
  echo "cpu_cores: $cores  cpu_threads: $(nproc --all)"
  echo "cpu_flags: ${flags:-none found}"
  echo "ram_total: $(free -h | awk '/^Mem:/{print $2}')"
  echo "rapl_power_limits: ${limits:-unreadable}"
  echo "kernel: $(uname -r)"
}

# write_meta <extra lines...>  -- records the conditions a sweep ran under
write_meta() {
  {
    echo "date: $(date -Iseconds)"
    echo "host: $(hostname)"
    echo "model_key: $MODEL_KEY"
    echo "model_file: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"
    echo "model_repo: $MODEL_REPO"
    echo "llama_cpp_version: $(llama_cpp_version)"
    echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)"
    echo "runs: $RUNS  cooldown_s: $COOLDOWN  threads: ${THREADS:-default}"
    echo "test_mode: ${TEST_MODE:-0}"
    hardware_summary
    for line in "$@"; do echo "$line"; done
  } > "$EXP_DIR/meta.txt"
}

require_model() {
  resolve_model "$1" || exit 1
  if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: model file not found: $MODEL_PATH" >&2
    echo "Run ./download_models.sh $MODEL_KEY first." >&2
    exit 1
  fi
  for b in "$BIN" "$TOKENIZE_BIN"; do
    [ -x "$b" ] || { echo "ERROR: missing llama.cpp binary: $b" >&2; exit 1; }
  done
  [ -r "$RAPL" ] || { echo "ERROR: cannot read $RAPL (run preflight.sh)" >&2; exit 1; }
}
