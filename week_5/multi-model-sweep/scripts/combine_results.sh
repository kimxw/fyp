#!/bin/bash
# Merges every per-model sweep_results.csv for an experiment into one file
# (the model is already a column), ready to paste/upload for analysis.
# Usage: ./combine_results.sh exp1_scaling | exp2_decode_strat | exp3_task_energy
set -e
source "$(dirname "$0")/common.sh"
EXP=${1:?"Usage: ./combine_results.sh <exp1_scaling|exp2_decode_strat|exp3_task_energy>"}
DEST=$RESULTS_DIR/$EXP/all_models.csv
mapfile -t FILES < <(find "$RESULTS_DIR/$EXP" -name sweep_results.csv -not -path "*smoke*" | sort)
[ ${#FILES[@]} -gt 0 ] || { echo "No results under $RESULTS_DIR/$EXP"; exit 1; }
head -1 "${FILES[0]}" > "$DEST"
for f in "${FILES[@]}"; do
  if [ "$(head -1 "$f")" != "$(head -1 "$DEST")" ]; then echo "WARNING: header differs, skipped: $f"; continue; fi
  tail -n +2 "$f" >> "$DEST"
  echo "  + $f ($(( $(wc -l < "$f") - 1 )) rows)"
done
echo "Wrote $DEST ($(( $(wc -l < "$DEST") - 1 )) rows)"
