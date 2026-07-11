#!/usr/bin/env bash
set -euo pipefail

# perf-compare.sh — run the pinned benchmark corpus and capture perf evidence.
#
# Usage:
#   scripts/perf-compare.sh <label> [outdir]
#   scripts/perf-compare.sh sweep  [outdir]
#
# <label>   — arbitrary string written into the output filenames, e.g. "before" or "after"
# [outdir]  — directory to write results into (default: ./perf-out)
#
# Environment variables:
#   REPEATS      — number of perf stat repetitions for Technique C (default: 20)
#   FIXTURE_GEN  — path to a command used by sweep mode (see below)
#
# Sweep mode (scripts/perf-compare.sh sweep):
#   Generates a synthetic fixture at N = 10 50 100 200 400 classes and records
#   the typecheck phase timer at each N.  Supply a custom generator via FIXTURE_GEN:
#     FIXTURE_GEN="my-gen.sh" scripts/perf-compare.sh sweep
#   The generator is called as: $FIXTURE_GEN <N> <output_file>
#   It must write a valid Ruby file to <output_file>.
#   If FIXTURE_GEN is unset, a built-in generator is used that emits N simple typed classes.
#
# Outputs (single-shot mode):
#   $OUTDIR/$LABEL.perf      — perf stat output (Technique C: instructions/cycles)
#   $OUTDIR/$LABEL.json      — --metrics-file JSON (Techniques B, D: counters + utilization)
#   $OUTDIR/$LABEL.counters  — --counters stderr (Techniques A, D: phase timers).
#                              This is the ONLY source of phase timers; --metrics-file
#                              carries no timers, only counters + run.utilization.

LABEL="${1:-}"
OUTDIR="${2:-./perf-out}"

if [[ -z "$LABEL" ]]; then
  echo "Usage: $0 <label|sweep> [outdir]" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

SORBET="${SORBET:-./bazel-bin/main/sorbet}"
CORPUS_LIST="test/benchmarks/corpus/FILELIST.txt"

if [[ ! -x "$SORBET" ]]; then
  echo "error: sorbet binary not found at $SORBET" >&2
  echo "Build it with: ./bazel build //main:sorbet -c opt" >&2
  exit 1
fi

if [[ ! -f "$CORPUS_LIST" ]]; then
  echo "error: corpus file list not found at $CORPUS_LIST" >&2
  exit 1
fi

mapfile -t corpus_files < "$CORPUS_LIST"
common_args=(--silence-dev-message --stop-after=inferencer "${corpus_files[@]}")

# ── Sweep mode ─────────────────────────────────────────────────────────────────
if [[ "$LABEL" == "sweep" ]]; then
  SWEEP_OUT="$OUTDIR/sweep.tsv"
  printf 'N\ttypecheck_ms\twall_ms\n' > "$SWEEP_OUT"

  _builtin_fixture_gen() {
    local n="$1"
    local out="$2"
    {
      printf '# typed: true\n\n'
      for i in $(seq 1 "$n"); do
        printf 'class BenchClass%d\n' "$i"
        printf '  sig { returns(Integer) }\n'
        printf '  def value; %d; end\n' "$i"
        printf 'end\n\n'
      done
    } > "$out"
  }

  TMPFILE=$(mktemp /tmp/sorbet-sweep-XXXXXX.rb)
  trap 'rm -f "$TMPFILE"' EXIT

  for N in 10 50 100 200 400; do
    if [[ -n "${FIXTURE_GEN:-}" ]]; then
      "$FIXTURE_GEN" "$N" "$TMPFILE"
    else
      _builtin_fixture_gen "$N" "$TMPFILE"
    fi

    OUT_JSON="$OUTDIR/sweep_N${N}.json"
    "$SORBET" --silence-dev-message --stop-after=inferencer \
      --metrics-file "$OUT_JSON" "$TMPFILE" >/dev/null 2>&1 || true

    COUNTERS_OUT=$( "$SORBET" --silence-dev-message --stop-after=inferencer \
      --counters "$TMPFILE" 2>&1 || true )
    TC_MS=$(printf '%s\n' "$COUNTERS_OUT" | awk '/typecheck\.value/{print $(NF-1)+0; found=1} END{if(!found) print 0}' | head -1)
    WALL_MS=$(printf '%s\n' "$COUNTERS_OUT" | awk '/wall_time\.value/{print $(NF-1)+0; found=1} END{if(!found) print 0}' | head -1)

    # A typecheck timer of 0ms at N>=50 is never legitimate — it means the run
    # failed or the timer was suppressed. Flag it but still record the row.
    if [[ "$N" -ge 50 && "$TC_MS" -eq 0 ]]; then
      echo "warning: N=$N produced typecheck=0ms — measurement likely failed (crash or suppressed histogram)" >&2
    fi

    printf '%d\t%s\t%s\n' "$N" "$TC_MS" "$WALL_MS" >> "$SWEEP_OUT"
    printf 'N=%d: typecheck=%sms wall=%sms\n' "$N" "$TC_MS" "$WALL_MS"
  done

  echo "wrote $SWEEP_OUT"
  exit 0
fi

# ── Single-shot mode ───────────────────────────────────────────────────────────

# Technique C: instruction count + cycles with stddev via perf stat
PERF_OUT="$OUTDIR/$LABEL.perf"
PERF=/usr/bin/perf
if [[ -x "$PERF" ]]; then
  "$PERF" stat -r "${REPEATS:-20}" -- "$SORBET" "${common_args[@]}" 2>"$PERF_OUT" || true
  echo "wrote $PERF_OUT"
else
  echo "warning: perf not found at $PERF — skipping Technique C (instruction count)" >&2
  printf 'perf unavailable\n' > "$PERF_OUT"
fi

# Techniques B, D (counters): counters + utilization via --metrics-file (JSON)
JSON_OUT="$OUTDIR/$LABEL.json"
"$SORBET" --metrics-file "$JSON_OUT" "${common_args[@]}" >/dev/null 2>&1 || true
echo "wrote $JSON_OUT"

# Techniques A, D (phase timers): --metrics-file JSON does NOT carry phase timers,
# only counters + run.utilization. Phase timers (typecheck.value, resolving.value,
# wall_time.value, per-phase histograms) appear only in --counters stderr output.
# The counters run prints type errors to stdout (harmless); we discard stdout and
# keep stderr.
#
# Sorbet occasionally SIGSEGVs on large multi-file inputs; when it does, the
# histogram block is never printed. Retry until we get a run that emitted the
# `wall_time.value` timer. If every attempt fails, write a sentinel marker and
# exit non-zero so perf-diff.sh can distinguish a crash from real data.
COUNTERS_OUT="$OUTDIR/$LABEL.counters"
COUNTERS_ATTEMPTS="${COUNTERS_ATTEMPTS:-5}"
counters_ok=0
for _ in $(seq 1 "$COUNTERS_ATTEMPTS"); do
  "$SORBET" --counters "${common_args[@]}" >/dev/null 2>"$COUNTERS_OUT" || true
  if grep -q 'wall_time\.value' "$COUNTERS_OUT"; then
    counters_ok=1
    break
  fi
done
if [[ "$counters_ok" -eq 1 ]]; then
  echo "wrote $COUNTERS_OUT"
else
  printf 'counters unavailable: all %s attempts crashed\n' "$COUNTERS_ATTEMPTS" > "$COUNTERS_OUT"
  echo "error: --counters run did not emit phase timers after $COUNTERS_ATTEMPTS attempts (sorbet crashed)" >&2
  echo "wrote $COUNTERS_OUT (sentinel)"
  exit 1
fi
