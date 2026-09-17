#!/bin/bash
# Writes <results dir>/hardware.txt: a one-off description of the machine a
# results folder was measured on (CPU, memory modules and channels, laptop
# model, power limits, llama.cpp build). run_model.sh calls this
# automatically the first time; rerun any time to refresh it.
#
# Usage:  ./record_hardware.sh                      (Lenovo, results/)
#         MACHINE=<label> ./record_hardware.sh      (results_<label>/)
# Uses sudo for dmidecode (memory modules, laptop model).
source "$(dirname "$0")/common.sh"
mkdir -p "$RESULTS_DIR"
OUT=$RESULTS_DIR/hardware.txt
{
  echo "# recorded $(date -Iseconds) on $(hostname)"
  hardware_summary
  echo "llama_cpp_version: $(llama_cpp_version)"
  echo "os: $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
  echo
  echo "## system"
  sudo dmidecode -t system 2>/dev/null | grep -E "Manufacturer|Product Name|Version" || echo "(dmidecode unavailable)"
  echo
  echo "## memory modules (Size 'No Module Installed' = empty slot -> single channel)"
  sudo dmidecode -t memory 2>/dev/null | grep -E "^\s+(Size|Locator|Bank Locator|Type|Speed|Configured Memory Speed):" || echo "(dmidecode unavailable)"
  echo
  echo "## lscpu"
  lscpu
} > "$OUT"
echo "Wrote $OUT"
grep -E "^(machine|cpu_model|ram_total)" "$OUT"
