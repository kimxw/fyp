#!/usr/bin/env python3
"""Merges one experiment's results across machines, adding a `machine` column.

Looks for results/ (the Lenovo, labelled lenovo-flex5-14iau7 unless
--default-label says otherwise) and every results_<machine>/ folder, reads
<exp>/all_models.csv (or all_models_rescored.csv with --rescored), and writes
hardware_comparison/<exp>[_rescored]_all_machines.csv.

Usage:
  python3 combine_machines.py exp1_scaling
  python3 combine_machines.py exp2_decode_strat --rescored
  python3 combine_machines.py exp3_task_energy --model llama-1b   (only that model)
Run combine_results.sh / rescore_code.py on each machine's folder first.
"""
import argparse
import csv
from pathlib import Path

WEEK5 = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exp", choices=["exp1_scaling", "exp2_decode_strat", "exp3_task_energy"])
    ap.add_argument("--rescored", action="store_true")
    ap.add_argument("--model", help="keep only this model key")
    ap.add_argument("--default-label", default="lenovo-flex5-14iau7")
    a = ap.parse_args()

    name = "all_models_rescored.csv" if a.rescored else "all_models.csv"
    rows, header = [], None
    for d in sorted(WEEK5.glob("results*")):
        if not d.is_dir():
            continue
        label = a.default_label if d.name == "results" else d.name[len("results_"):]
        src = d / a.exp / name
        if not src.exists():
            print(f"  skip {d.name}: no {a.exp}/{name}")
            continue
        with src.open(newline="") as f:
            r = csv.DictReader(f)
            if header is None:
                header = ["machine"] + r.fieldnames
            elif ["machine"] + r.fieldnames != header:
                print(f"  WARNING: {src} has different columns, skipped")
                continue
            n = 0
            for row in r:
                if a.model and row["model"] != a.model:
                    continue
                rows.append({"machine": label, **row})
                n += 1
        print(f"  + {label}: {n} rows")
    if not rows:
        raise SystemExit("nothing to combine")
    out_dir = WEEK5 / "hardware_comparison"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / f"{a.exp}{'_rescored' if a.rescored else ''}_all_machines.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header)
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {out.relative_to(WEEK5)} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
