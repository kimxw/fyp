# multi-model-sweep (week 5)

Repeat of the week 3 CPU baseline (week_3/fernandez-cpu-followup) with more models and more data points.
Same rig (Lenovo, llama.cpp, RAPL package-0), same task, Q4_K_M for every model.

## Models

| Size  | Model                        | Role                                        |
|-------|------------------------------|---------------------------------------------|
| Small | Llama-3.2-1B-Instruct        | anchor to week 3 data                       |
| Small | Qwen2.5-Coder-1.5B-Instruct  | coder size ladder, step 1                   |
| Mid   | Llama-3.2-3B-Instruct        | Llama 1B -> 3B (already downloaded)         |
| Mid   | Qwen2.5-Coder-3B-Instruct    | coder size ladder, step 2                   |
| Large | Qwen2.5-Coder-7B-Instruct    | coder size ladder, step 3                   |
| Large | DeepSeek-R1-Distill-Qwen-7B  | reasoning vs non-reasoning at 7B            |

## Comparisons
1. Size scaling within a family (Qwen-Coder 1.5/3/7B, Llama 1/3B)
2. Family at matched size (Llama vs Qwen, ~1-3B)
3. Reasoning vs non-reasoning at 7B (caveat: R1-Distill is Qwen2.5-Math based, not Coder)
4. Energy per completed task, incl. reasoning tokens and whether the code passes tests (exp3, new)

## Layout
- `RUNBOOK.md` - every command to run, in order
- `scripts/` - `exp1_scaling.sh`, `exp2_decode_strat.sh`, `exp3_task_energy.sh` (each takes a model key),
  plus `models.sh` (registry), `common.sh` (shared helpers), `check_code.py`, `download_models.sh`,
  `check_setup.sh`, `combine_results.sh`, `rescore_code.py`, `preflight.sh`
- `results/<experiment>/<model-key>/` - `sweep_results.csv`, `timeseries.csv`, `meta.txt`, `raw/`

## More data points
- 8 input lengths and 8 output lengths (week 3: 5 and 6), 5 repeats instead of 3
- Reasoning model: output cap 2048 (exp2) / 4096 (exp3); thinking and answer tokens recorded separately
- Every run checks whether the generated code parses and passes a few sort tests

## To check before running
- Lenovo RAM (7B at Q4 needs ~5 GB free) - `scripts/check_setup.sh` prints it
- Which of these models appear on the AI Energy Score leaderboard (compare rankings only)
