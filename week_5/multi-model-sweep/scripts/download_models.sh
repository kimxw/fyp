#!/bin/bash
# Downloads the Q4_K_M GGUF for each model (skips ones already present).
# Usage: ./download_models.sh            (all six)
#        ./download_models.sh <key> ...  (just these)
# Needs the Hugging Face CLI:  pip install -U huggingface_hub   (provides `hf`)
set -e
source "$(dirname "$0")/common.sh"
mkdir -p "$MODELS_DIR"
KEYS=("$@")
[ ${#KEYS[@]} -eq 0 ] && mapfile -t KEYS < <(list_model_keys)
for key in "${KEYS[@]}"; do
  resolve_model "$key" || exit 1
  if [ -f "$MODEL_PATH" ]; then
    echo "[skip] $key already at $MODEL_PATH"
    continue
  fi
  echo "[get ] $key from $MODEL_REPO"
  hf download "$MODEL_REPO" --include "*Q4_K_M.gguf" --local-dir "$MODELS_DIR"
  resolve_model "$key"
  [ -f "$MODEL_PATH" ] || { echo "ERROR: download finished but $MODEL_PATH not found; check the file name in $MODELS_DIR" >&2; exit 1; }
done
echo "Models in $MODELS_DIR:"; ls -lh "$MODELS_DIR"/*.gguf
