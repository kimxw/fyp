#!/bin/bash
# Model registry for week 5. Sourced by the other scripts, not run directly.
#
# Format: key|huggingface_repo|gguf_stem|size_class|is_reasoning
# All models are Q4_K_M; the file on disk is  $MODELS_DIR/<gguf_stem>-Q4_K_M.gguf
MODEL_REGISTRY=(
  "llama-1b|bartowski/Llama-3.2-1B-Instruct-GGUF|Llama-3.2-1B-Instruct|small|0"
  "qwen-coder-1.5b|bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF|Qwen2.5-Coder-1.5B-Instruct|small|0"
  "llama-3b|bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct|mid|0"
  "qwen-coder-3b|bartowski/Qwen2.5-Coder-3B-Instruct-GGUF|Qwen2.5-Coder-3B-Instruct|mid|0"
  "qwen-coder-7b|bartowski/Qwen2.5-Coder-7B-Instruct-GGUF|Qwen2.5-Coder-7B-Instruct|large|0"
  "r1-distill-qwen-7b|bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF|DeepSeek-R1-Distill-Qwen-7B|large|1"
)

list_model_keys() {
  local entry
  for entry in "${MODEL_REGISTRY[@]}"; do echo "${entry%%|*}"; done
}

# resolve_model <key>
# Sets: MODEL_KEY MODEL_REPO MODEL_STEM MODEL_SIZE IS_REASONING MODEL_PATH
resolve_model() {
  local want=$1 entry
  for entry in "${MODEL_REGISTRY[@]}"; do
    IFS='|' read -r k repo stem size reasoning <<< "$entry"
    if [ "$k" = "$want" ]; then
      MODEL_KEY=$k; MODEL_REPO=$repo; MODEL_STEM=$stem
      MODEL_SIZE=$size; IS_REASONING=$reasoning
      MODEL_PATH=$MODELS_DIR/${stem}-Q4_K_M.gguf
      if [ ! -f "$MODEL_PATH" ]; then
        # fall back to a case-insensitive match (some repos use lowercase names)
        local found
        found=$(find "$MODELS_DIR" -maxdepth 1 -iname "${stem}-Q4_K_M.gguf" | head -1)
        [ -n "$found" ] && MODEL_PATH=$found
      fi
      return 0
    fi
  done
  echo "ERROR: unknown model key '$want'. Valid keys:" >&2
  list_model_keys | sed 's/^/  /' >&2
  return 1
}
