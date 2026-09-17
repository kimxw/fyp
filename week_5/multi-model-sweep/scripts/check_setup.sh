#!/bin/bash
# Quick sanity check before a week 5 session: RAM, disk, binaries, models.
source "$(dirname "$0")/common.sh"
echo "== Machine: ${MACHINE:-default (Lenovo)}  ->  results in $RESULTS_DIR"
hardware_summary | sed 's/^/  /'
echo "== RAM";  free -h | head -2
echo "== Disk ($MODELS_DIR)"; df -h "$MODELS_DIR" 2>/dev/null | tail -1
echo "== llama.cpp ($LLAMA_DIR) version: $(llama_cpp_version)"
for b in "$BIN" "$TOKENIZE_BIN"; do [ -x "$b" ] && echo "  ok  $b" || echo "  MISSING $b"; done
echo "== RAPL"; [ -r "$RAPL" ] && echo "  ok  $RAPL (max range ${RAPL_MAX} uJ)" || echo "  NOT READABLE $RAPL (run preflight.sh)"
echo "== Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
echo "== Models"
for key in $(list_model_keys); do
  resolve_model "$key"
  if [ -f "$MODEL_PATH" ]; then
    n=$(token_count "$CORE_TASK")
    printf "  ok       %-20s %6s  task=%s tokens\n" "$key" "$(du -h "$MODEL_PATH" | cut -f1)" "$n"
  else
    printf "  MISSING  %-20s (./download_models.sh %s)\n" "$key" "$key"
  fi
done
