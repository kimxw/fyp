# Week 5 runbook: multi-model sweep

Everything below runs **on the Lenovo** unless marked *(Mac)*.
Commands assume the week 5 folder sits at `~/fyp/week_5/multi-model-sweep` on the Lenovo,
and that llama.cpp and models stay where week 3 put them (`~/fyp/fernandez-cpu-followup/`).
If either lives elsewhere, set `LLAMA_DIR=...` / `MODELS_DIR=...` in front of any command.

Model keys: `llama-1b`, `qwen-coder-1.5b`, `llama-3b`, `qwen-coder-3b`, `qwen-coder-7b`, `r1-distill-qwen-7b`

---

## 0. One-time setup

```bash
# (Mac) get the folder onto the Lenovo - git pull, scp or USB, e.g.
scp -r ~/Projects/fyp/week_5/multi-model-sweep <lenovo-user>@<lenovo-ip>:~/fyp/week_5/

# (Lenovo)
cd ~/fyp/week_5/multi-model-sweep/scripts
chmod +x *.sh *.py

# Hugging Face CLI, if `hf` isn't installed yet
pip install -U huggingface_hub

# Download the models (Wi-Fi ON for this). ~15 GB total; llama-3b is already there.
./download_models.sh
#   or one at a time:  ./download_models.sh qwen-coder-7b

# Check RAM, disk, binaries, RAPL and that every model loads in the tokenizer
./check_setup.sh
```

Check in the `check_setup.sh` output:
- **RAM**: the 7B models need about 5 GB free. With 8 GB total, close everything else before 7B runs.
- **Models**: all six show `ok`. If one shows MISSING after downloading, look at the file name in the models folder (`ls ~/fyp/fernandez-cpu-followup/models`) and fix the stem in `scripts/models.sh`.
- **task=N tokens**: this differs between Llama and Qwen. That's expected (different tokenizers), and why every CSV uses actual token counts.

## 1. Start of every session

```bash
cd ~/fyp/week_5/multi-model-sweep/scripts
./preflight.sh          # governor -> performance, Wi-Fi off, display off, RAPL check
./check_setup.sh        # confirm governor + RAPL
```

Run long sweeps inside `tmux` so they survive the screen going off:
```bash
tmux new -s sweep       # detach: Ctrl-b d     reattach: tmux attach -t sweep
```

## One model, everything (quickest path)

```bash
cd ~/fyp/week_5/multi-model-sweep/scripts
./run_model.sh <model-key> --smoke     # ~1-5 min sanity check, saved as *_smoke
./run_model.sh <model-key>             # exp3 -> exp2 -> exp1, then merges all_models.csv
```
Console output is saved to `results/logs/<model>_<timestamp>.log`. If it gets interrupted, rerun the
same command: finished experiments are skipped and the unfinished one restarts.
The sections below run the experiments one at a time instead.

## 2. Smoke tests (do these first, ~20-30 min total)

One run per model per experiment, results tagged `_smoke` so they never mix with real data.

```bash
for m in llama-1b qwen-coder-1.5b llama-3b qwen-coder-3b qwen-coder-7b r1-distill-qwen-7b; do
  TEST_MODE=1 ./exp1_scaling.sh      "$m" smoke
  TEST_MODE=1 ./exp2_decode_strat.sh "$m" "" smoke
  TEST_MODE=1 ./exp3_task_energy.sh  "$m" smoke
done
```

Then check by hand before the real runs:
```bash
cd ../results
cat exp3_task_energy/*_smoke/sweep_results.csv     # energy, tokens, code checks look sane?
cat exp3_task_energy/r1-distill-qwen-7b_smoke/raw/task_run1.txt
```
- **R1 output**: the `.txt` should show the thinking and then the answer. If `think_tokens` is 0 even though the text clearly has reasoning, the thinking markers in your llama.cpp build differ from `<think>` / `[Start thinking]`. Send me the `.txt` and I'll adjust `check_code.py`.
- **Qwen output**: make sure the `.txt` files contain only the model's reply. If the prompt or chat headers leaked in, the text extraction needs adjusting for that template.
- **Code checks**: `passes_tests` should be 1 for at least the coder models. If a correct-looking answer gets 0, send me the `.txt`.

## 3. Experiment 1: prefill/decode scaling

8 input lengths (128-2048, output 64) + 8 output lengths (8-512, input 512), 5 repeats = **80 runs per model**.

```bash
cd ~/fyp/week_5/multi-model-sweep/scripts
./exp1_scaling.sh llama-1b
./exp1_scaling.sh qwen-coder-1.5b
./exp1_scaling.sh llama-3b
./exp1_scaling.sh qwen-coder-3b
./exp1_scaling.sh qwen-coder-7b
./exp1_scaling.sh r1-distill-qwen-7b
```

Or all in one go (e.g. overnight):
```bash
for m in llama-1b qwen-coder-1.5b llama-3b qwen-coder-3b qwen-coder-7b r1-distill-qwen-7b; do
  ./exp1_scaling.sh "$m" 2>&1 | tee -a ../results/exp1_session.log
done
```

Optional extra run: forces exactly N output tokens, so the output sweep isn't cut short by the model stopping early (week 3 finding #4). Tagged separately.
```bash
IGNORE_EOS=1 ./exp1_scaling.sh llama-1b fixedlen
```

Results: `results/exp1_scaling/<model>/` (`sweep_results.csv`, `timeseries.csv`, `meta.txt`, `raw/`)

## 4. Experiment 2: decoding strategies

greedy / temperature / top_p / top_k, input 512, 5 repeats = **20 runs per model**.
Budget: 256 by default (same as week 3's long run); 2048 for the R1 model so its thinking can finish.

```bash
./exp2_decode_strat.sh llama-1b
./exp2_decode_strat.sh qwen-coder-1.5b
./exp2_decode_strat.sh llama-3b
./exp2_decode_strat.sh qwen-coder-3b
./exp2_decode_strat.sh qwen-coder-7b
RUNS=3 ./exp2_decode_strat.sh r1-distill-qwen-7b      # 3 repeats: each run can take ~10 min
```

Optional: rerun the week 3 short budget for continuity: `./exp2_decode_strat.sh llama-1b 128`

Results: `results/exp2_decode_strat/out<budget>/<model>/`

## 5. Experiment 3: energy per completed task (new)

Bare task prompt, model stops when done (cap 1024 tokens, 4096 for R1), same sampling for all
(temp 0.6, top-p 0.95), 5 repeats. Records thinking vs answer tokens and whether the code passes the tests.

```bash
for m in llama-1b qwen-coder-1.5b llama-3b qwen-coder-3b qwen-coder-7b r1-distill-qwen-7b; do
  ./exp3_task_energy.sh "$m"
done
```
If `hit_budget=1` shows up for R1, it ran out of tokens mid-thought. Rerun with a bigger cap:
```bash
MAX_TOKENS=8192 ./exp3_task_energy.sh r1-distill-qwen-7b cap8192
```

Results: `results/exp3_task_energy/<model>/`

## 6. Wrap up

```bash
./combine_results.sh exp1_scaling        # -> results/exp1_scaling/all_models.csv
./combine_results.sh exp2_decode_strat
./combine_results.sh exp3_task_energy
nmcli radio wifi on

# (Mac) copy results back into the repo
scp -r <lenovo-user>@<lenovo-ip>:~/fyp/week_5/multi-model-sweep/results/* ~/Projects/fyp/week_5/multi-model-sweep/results/
```
Then share the three `all_models.csv` files for analysis.

Re-check the code of finished runs with the current checker (writes `*_rescored.csv` next to
the originals, which stay untouched; nothing is re-run):
```bash
python3 scripts/rescore_code.py              # or: python3 scripts/rescore_code.py ../results_<machine>
```
The Lenovo llama-1b / llama-3b runs were scored by the harness from commit 7d8b567 (unchanged through eed365e), which failed any
run cut off mid example-usage line even when the function was complete. `passes_tests_v2` in the
rescored CSVs is the corrected column and is what the week 5 report uses.

---

## Rough timings (estimates from week 3 speeds; 7B speeds are a guess)

| Model size | Exp 1 (80 runs) | Exp 2 (20 runs) | Exp 3 (5 runs) |
|---|---|---|---|
| 1-1.5B | ~30 min | ~10 min | ~5 min |
| 3B | ~1 h | ~25 min | ~10 min |
| 7B coder | ~2.5 h | ~45 min | ~15 min |
| 7B R1 | ~2.5 h | ~2 h (3 repeats, budget 2048) | up to ~2 h |

Total: roughly 12-15 hours of rig time. Run exp1 overnight in tmux.

## Handy options (any script)

| Variable | Default | Effect |
|---|---|---|
| `RUNS` | 5 | repeats per point |
| `COOLDOWN` | 8 | seconds idle before each run |
| `THREADS` | llama.cpp default | pin thread count (`-t`) |
| `FORCE=1` | off | overwrite an existing results folder (otherwise it refuses) |
| `TEST_MODE=1` | off | single-run smoke test |
| `INPUT_LENGTHS` / `OUTPUT_LENGTHS` | see exp1 | e.g. `INPUT_LENGTHS="128 512 2048"` to trim a 7B sweep |
| `IGNORE_EOS=1` | off | exp1 only: force exact output lengths |
| `MAX_TOKENS` / `TASK_SAMPLING` | 1024 (4096 R1) / temp 0.6 top-p 0.95 | exp3 only |
| `LLAMA_DIR` / `MODELS_DIR` / `RESULTS_DIR` | week 3 paths / `../results` | relocate things |

## What changed vs week 3

- Model is an argument; results land in one folder per model, and the model is a CSV column.
- More points (8 input and 8 output lengths instead of 5 and 6) and 5 repeats instead of 3.
- Exp 2 writes `contains_return` properly. The week 3 `out256` CSV has it in the header but not in the rows, so every column after `output_tokens_actual` is shifted by one there.
- `\r` is stripped from captured text. `script` records lines as `\r\n`, which slightly affected week 3 token counts.
- New columns: thinking vs answer tokens, `hit_budget`, whether the code has valid syntax and passes tests, and `run_ok` (a failed run is recorded instead of stopping the sweep).
- The RAPL counter wrapping around is handled. A `meta.txt` per sweep records the llama.cpp commit, governor, lengths and sampling.
- Refuses to overwrite existing results, which avoids the half-overwritten folders from week 3's Exp 3.
