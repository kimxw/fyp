#!/usr/bin/env python3
"""Re-scores the code checks of finished runs with the current check_code.py.

Why: the harness that produced the week 5 Lenovo runs (scripts from commit
7d8b567, unchanged through eed365e) marked a run as failing whenever the output was cut off part-way
through an example-usage line, even if the function above it was complete.
check_code.py now drops trailing lines that don't parse before testing.
The saved model outputs (raw/*.txt) are re-checked; nothing is re-run.

For every exp2_decode_strat / exp3_task_energy results folder under the
results directory, writes next to sweep_results.csv:
    sweep_results_rescored.csv   original columns + has_code_v2, syntax_ok_v2, passes_tests_v2
and per experiment:
    <experiment>/all_models_rescored.csv   (smoke-test folders excluded)
The original CSVs are never modified.

Usage:  python3 rescore_code.py [results-dir]      (default: ../results)
Note: this executes the model-written functions (defs/imports only, 10 s
timeout), same as the harness does.
"""
import csv
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECKER = HERE / "check_code.py"
EXPS = {"exp2_decode_strat": lambda row: f"{row['strategy']}_run{row['run']}",
        "exp3_task_energy": lambda row: f"task_run{row['run']}"}
NEW = ["has_code_v2", "syntax_ok_v2", "passes_tests_v2"]


def check(txt: Path):
    if not txt.exists():
        return ["NA"] * 3
    r = subprocess.run([sys.executable, str(CHECKER)], stdin=txt.open("rb"),
                       capture_output=True, text=True, timeout=60)
    parts = r.stdout.strip().split(",")
    return parts if len(parts) == 3 else ["NA"] * 3


def main():
    results = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (HERE.parent / "results")
    for exp, stem in EXPS.items():
        root = results / exp
        if not root.is_dir():
            continue
        combined, header = [], None
        for csv_path in sorted(root.rglob("sweep_results.csv")):
            with csv_path.open(newline="") as f:
                reader = csv.DictReader(f)
                fields = reader.fieldnames + NEW
                rows = list(reader)
            changed = 0
            for row in rows:
                v2 = check(csv_path.parent / "raw" / f"{stem(row)}.txt")
                row.update(dict(zip(NEW, v2)))
                changed += row.get("passes_tests") != row["passes_tests_v2"]
            out = csv_path.with_name("sweep_results_rescored.csv")
            with out.open("w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=fields)
                w.writeheader()
                w.writerows(rows)
            rel = csv_path.parent.relative_to(results)
            print(f"  {rel}: {len(rows)} runs, passes_tests changed in {changed}")
            if "smoke" in csv_path.parent.name:
                continue
            if header is None:
                header = fields
            if fields == header:
                combined += rows
            else:
                print(f"  WARNING: header differs, not combined: {rel}")
        if header:
            dest = root / "all_models_rescored.csv"
            with dest.open("w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=header)
                w.writeheader()
                w.writerows(combined)
            print(f"Wrote {dest.relative_to(results)} ({len(combined)} rows)")


if __name__ == "__main__":
    main()
