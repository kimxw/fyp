# fernandez-cpu-followup (week 3)

Phase-one CPU inference energy baseline on the Lenovo (llama.cpp, RAPL).
Scripts run on the Lenovo; results are copied here for analysis.

## Layout

- `scripts/` - sweep scripts (run on the Lenovo; each takes the output folder name as its argument)
  - `preflight.sh` - one-off setup before a sweep session (CPU governor etc.)
  - `sweep.sh` - Exp 1, prefill/decode scaling (Run A)
  - `sweep2.sh` - Exp 1 with per-run timeseries (Run B)
  - `sweep_decode_strat.sh` - Exp 2, decoding strategies, 128-token output
  - `sweep_decode_strat_long.sh` - Exp 2, decoding strategies, 256-token output
  - `sweep_speculative_decode.sh` - Exp 3, standard vs speculative decoding (3B target, 1B draft)
- `results/`
  - `exp1_prefill_decode_scaling/`
    - `runA/` - 21 runs (3 input x 3, 4 output x 3)
    - `runB_timeseries/` - 33 runs (5 input x 3, 6 output x 3) + timeseries.csv
    - `smoke_test/`
  - `exp2_decode_strategy/`
    - `out128/` - greedy / temperature / top_p / top_k, 128-token budget
    - `out256/` - same, 256-token budget
    - `smoke_test/`
  - `exp3_speculative_decode/`
    - no speculative-decoding runs were completed; Exp 3 is not in the results sheet
    - `smoke_test/`
    - `attempt1_incomplete/` - aborted: 4 Sep 07:56, 1 standard run completed, run 2 empty
    - `attempt2_incomplete/` - aborted: 4 Sep 08:15, 1 standard run completed, run 2 empty
- `report/` - condensed results sheet shown to FYP prof (`fyp_print_data`, .docx + .pdf) and the experiment log (`fyp_log.docx`)

Note: result folders were renamed during reorganisation, so they no longer match
the names originally passed to the scripts (e.g. `exp1-prefill-decode-scaling` -> `exp1_prefill_decode_scaling/runA`).
