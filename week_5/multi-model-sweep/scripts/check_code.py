#!/usr/bin/env python3
"""Post-run checks on a model's generated text (read from stdin).

  check_code.py --part think    print only the reasoning part (empty if none)
  check_code.py --part answer   print only the part after the reasoning
  check_code.py                 print "has_code,syntax_ok,passes_tests"

The test step extracts the Python code from the answer, keeps only the
imports / function / class definitions (so example usage or input() calls
don't run), then calls each function on a few lists and checks that the
result is sorted. A function passes if it returns the sorted list OR sorts
the list in place and returns None. Runs in a separate process with a
timeout. This runs model-written code on the rig: fine for bubble sort,
but read the saved outputs before reusing this for other tasks.
"""
import argparse
import ast
import re
import subprocess
import sys
import tempfile

# Markers used by reasoning models / llama-cli for the thinking section
THINK_END = re.compile(r"</think>|\[End thinking\]", re.I)
THINK_START = re.compile(r"<think>|\[Start thinking\]", re.I)

CASES = [[5, 1, 4, 2, 8], [], [1], [3, 3, 1, 2], [-2, 7, 0, -5, 7.5],
         [9, 8, 7, 6, 5, 4, 3, 2, 1], [2, 1]]

HARNESS = r'''
import copy, inspect, json, sys
ns = {}
exec(open(sys.argv[1]).read(), ns)
cases = json.loads(sys.argv[2])
ok = False
for name, fn in list(ns.items()):
    if not inspect.isfunction(fn):
        continue
    try:
        params = [p for p in inspect.signature(fn).parameters.values()
                  if p.default is p.empty and p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
    except (TypeError, ValueError):
        continue
    if len(params) != 1:
        continue
    try:
        good = True
        for case in cases:
            arg = copy.deepcopy(case)
            ret = fn(arg)
            got = arg if ret is None else ret
            if list(got) != sorted(case):
                good = False
                break
        if good:
            ok = True
            break
    except Exception:
        continue
print(1 if ok else 0)
'''


def split(text):
    parts = THINK_END.split(text, maxsplit=1)
    if len(parts) == 2:
        think, answer = parts
    elif THINK_START.search(text):
        # started thinking but never finished (hit the token budget)
        think, answer = text, ""
    else:
        think, answer = "", text
    return THINK_START.sub("", think).strip(), answer.strip()


def extract_code(answer):
    blocks = re.findall(r"```[ \t]*(?:python|py|python3)?[ \t]*\n(.*?)```", answer, re.S | re.I)
    if blocks:
        return "\n\n".join(blocks)
    # a block that was opened but cut off before closing
    m = re.search(r"```[ \t]*(?:python|py|python3)?[ \t]*\n(.*)", answer, re.S | re.I)
    if m:
        return m.group(1)
    return answer if re.search(r"^\s*def \w+\(", answer, re.M) else ""


def parse_trimmed(code):
    """Parse the code; if that fails, drop trailing lines one at a time.

    Output cut off by the token budget usually ends mid-way through an
    example-usage line after a complete function. Trimming recovers the
    function; a function that is itself cut off still fails (no body, or
    fails the tests)."""
    lines = code.rstrip().split("\n")
    while lines:
        try:
            tree = ast.parse("\n".join(lines))
            if any(isinstance(n, ast.FunctionDef) for n in tree.body):
                return tree
            return None
        except SyntaxError:
            lines.pop()
    return None


def check(answer):
    code = extract_code(answer)
    if not re.search(r"^\s*def \w+\(", code, re.M):
        return 0, 0, 0
    tree = parse_trimmed(code)
    if tree is None:
        return 1, 0, 0
    keep = (ast.FunctionDef, ast.ClassDef, ast.Import, ast.ImportFrom)
    tree.body = [n for n in tree.body if isinstance(n, keep)]
    src = ast.unparse(tree)
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(src)
        path = f.name
    import json
    try:
        r = subprocess.run([sys.executable, "-I", "-c", HARNESS, path, json.dumps(CASES)],
                           capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        passed = 1 if r.stdout.strip() == "1" else 0
    except subprocess.TimeoutExpired:
        passed = 0
    return 1, 1, passed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--part", choices=["think", "answer"])
    args = ap.parse_args()
    text = sys.stdin.read().replace("\r\n", "\n").replace("\r", "\n")
    think, answer = split(text)
    if args.part == "think":
        print(think)
    elif args.part == "answer":
        print(answer)
    else:
        print(",".join(map(str, check(answer))))


if __name__ == "__main__":
    main()
