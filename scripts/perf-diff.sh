#!/usr/bin/env bash
set -euo pipefail

# perf-diff.sh — compare two perf-compare.sh runs and print a delta table.
#
# Usage:
#   scripts/perf-diff.sh [outdir]
#
# Reads $OUTDIR/before.json, $OUTDIR/after.json,
#       $OUTDIR/before.perf, $OUTDIR/after.perf,
#       $OUTDIR/before.counters, $OUTDIR/after.counters
# and prints before / after / delta tables to stdout:
#   1. counter deltas (from the .json metrics files)
#   2. phase-timer deltas (from the .counters files — Technique A/D)
#   3. instruction/cycle deltas (from the .perf files — Technique C)
#
# [outdir] defaults to ./perf-out

OUTDIR="${1:-./perf-out}"

BEFORE_JSON="$OUTDIR/before.json"
AFTER_JSON="$OUTDIR/after.json"
BEFORE_PERF="$OUTDIR/before.perf"
AFTER_PERF="$OUTDIR/after.perf"
BEFORE_COUNTERS="$OUTDIR/before.counters"
AFTER_COUNTERS="$OUTDIR/after.counters"

for f in "$BEFORE_JSON" "$AFTER_JSON"; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found — run scripts/perf-compare.sh before/after first" >&2
    exit 1
  fi
done

echo "=== Counter deltas (from --metrics-file JSON) ==="

# ── JSON counter diff (Techniques B, D counters) ───────────────────────────────
python3 - "$BEFORE_JSON" "$AFTER_JSON" <<'PYEOF'
import json
import sys

def load(path):
    with open(path) as f:
        data = json.load(f)
    return {m["name"]: m["value"] for m in data.get("metrics", [])}

before = load(sys.argv[1])
after  = load(sys.argv[2])

# Keys of interest: any metric name containing these substrings
PATTERNS = ["infer", "resolv", "namer", "index", "typecheck", "methods.total",
            "methods.typechecked", "sig.count", "input.files", "input.bytes",
            "user_time", "system_time"]

all_keys = sorted(set(before) | set(after))
interesting = [k for k in all_keys
               if any(p in k.lower() for p in PATTERNS)]

if not interesting:
    interesting = all_keys

col_w = max(len(k) for k in interesting) if interesting else 40
header = f"{'metric':<{col_w}}  {'before':>12}  {'after':>12}  {'delta':>12}  {'delta%':>8}"
sep    = "-" * len(header)
print(header)
print(sep)

for k in interesting:
    bv = before.get(k)
    av = after.get(k)
    if bv is None and av is None:
        continue
    bv = bv or 0
    av = av or 0
    delta = av - bv
    pct   = (delta / bv * 100) if bv != 0 else float("nan")
    pct_s = f"{pct:+.2f}%" if bv != 0 else "  n/a"
    print(f"{k:<{col_w}}  {bv:>12}  {av:>12}  {delta:>+12}  {pct_s:>8}")
PYEOF

# ── Phase-timer diff (Technique A/D) from --counters output ─────────────────────
echo ""
echo "=== Phase-timer deltas (ms, from --counters histograms) ==="
if [[ ! -f "$BEFORE_COUNTERS" || ! -f "$AFTER_COUNTERS" ]]; then
  echo "phase-timer .counters files not found — skipping Technique A/D table"
elif grep -q "counters unavailable" "$BEFORE_COUNTERS" 2>/dev/null \
  || grep -q "counters unavailable" "$AFTER_COUNTERS" 2>/dev/null; then
  echo "(counters unavailable — run crashed)"
else
  python3 - "$BEFORE_COUNTERS" "$AFTER_COUNTERS" <<'PYEOF'
import re
import sys

# Timer lines look like:  "   typecheck.value :             96 ms"
LINE = re.compile(r"^\s*([\w.]+)\.value\s*:\s*([\d.]+)\s*ms\s*$")

def load(path):
    timers = {}
    with open(path) as f:
        for line in f:
            m = LINE.match(line)
            if m:
                timers[m.group(1)] = float(m.group(2))
    return timers

before = load(sys.argv[1])
after  = load(sys.argv[2])

keys = sorted(set(before) | set(after))
if not keys:
    print("(no phase timers parsed)")
    sys.exit(0)

col_w = max(len(k) for k in keys)
header = f"{'timer':<{col_w}}  {'before_ms':>10}  {'after_ms':>10}  {'delta_ms':>10}  {'delta%':>8}"
sep    = "-" * len(header)
print(header)
print(sep)

for k in keys:
    bv = before.get(k)
    av = after.get(k)
    bv_s = f"{bv:g}" if bv is not None else "n/a"
    av_s = f"{av:g}" if av is not None else "n/a"
    if bv is None or av is None:
        print(f"{k:<{col_w}}  {bv_s:>10}  {av_s:>10}  {'n/a':>10}  {'n/a':>8}")
        continue
    delta = av - bv
    pct   = (delta / bv * 100) if bv != 0 else float("nan")
    pct_s = f"{pct:+.2f}%" if bv != 0 else "  n/a"
    print(f"{k:<{col_w}}  {bv:>10g}  {av:>10g}  {delta:>+10g}  {pct_s:>8}")
PYEOF
fi

# ── perf stat diff (Technique C) ───────────────────────────────────────────────
echo ""
echo "=== Instruction/cycle deltas (from perf stat) ==="
for pf in "$BEFORE_PERF" "$AFTER_PERF"; do
  if [[ ! -f "$pf" ]] || grep -q "perf unavailable" "$pf" 2>/dev/null; then
    echo "perf stat output unavailable — skipping instruction-count diff"
    exit 0
  fi
done

python3 - "$BEFORE_PERF" "$AFTER_PERF" <<'PYEOF'
import re
import sys

# Under `perf stat -r N`, each event line looks like:
#     1,234,567,890      instructions   #  1.23  insn per cycle   ( +-  0.15% )
#       987,654,321      cycles                                   ( +-  0.32% )
# The mean is the leading comma-grouped integer; the stddev (when N>1) is the
# "+- X.XX%" suffix. task-clock is deliberately NOT parsed: it is a fractional
# "msec" value whose formatting differs, and instructions+cycles are the
# Technique C signal.
WANT = ("instructions", "cycles")

def parse(path):
    result = {}
    with open(path) as f:
        for line in f:
            for metric in WANT:
                # Anchor on the metric name preceded by its count, so we don't
                # match the same token inside a "# ... insn per cycle" comment.
                m = re.search(
                    r"([\d,]+)\s+" + re.escape(metric) + r"\b"
                    r"(?:.*?\(\s*\+-\s*([\d.]+)%\s*\))?",
                    line,
                )
                if m:
                    mean = int(m.group(1).replace(",", ""))
                    stddev_pct = float(m.group(2)) if m.group(2) else None
                    result[metric] = (mean, stddev_pct)
    return result

before = parse(sys.argv[1])
after  = parse(sys.argv[2])

keys = [k for k in WANT if k in before or k in after]
if not keys:
    print("(no perf metrics parsed)")
    sys.exit(0)

col_w = max(len(k) for k in keys)
header = (f"{'perf metric':<{col_w}}  {'before':>16}  {'±b%':>6}  "
          f"{'after':>16}  {'±a%':>6}  {'delta':>16}  {'delta%':>8}")
sep    = "-" * len(header)
print(header)
print(sep)

def fmt_sd(sd):
    return f"{sd:.2f}" if sd is not None else "n/a"

for k in keys:
    b = before.get(k)
    a = after.get(k)
    bv = b[0] if b else 0
    av = a[0] if a else 0
    bsd = b[1] if b else None
    asd = a[1] if a else None
    delta = av - bv
    pct   = (delta / bv * 100) if bv != 0 else float("nan")
    pct_s = f"{pct:+.2f}%" if bv != 0 else "  n/a"
    print(f"{k:<{col_w}}  {bv:>16,}  {fmt_sd(bsd):>6}  "
          f"{av:>16,}  {fmt_sd(asd):>6}  {delta:>+16,}  {pct_s:>8}")
PYEOF
