# Benchmark Corpus

This directory contains the pinned benchmark corpus used by `scripts/perf-compare.sh`.

## Contents

`FILELIST.txt` — one relative path per line (from the repo root), listing the exact set of files
fed to Sorbet on every benchmark run. The paths point to committed in-tree sources, so the corpus
is implicitly pinned to the repo's own git SHA at HEAD. Nothing is duplicated or copied.

### Included paths

| Directory | File type | Purpose |
|-----------|-----------|---------|
| `test/testdata/infer/` | `.rb` | Type-inference test cases — the primary inferencer load |
| `test/testdata/cfg/` | `.rb` | CFG-construction test cases |
| `test/testdata/core/` | `.rb` | Core type-system test cases |
| `test/testdata/namer/` | `.rb` | Namer-phase test cases |
| `rbi/core/` | `.rbi` | Core Ruby RBI definitions (Array, Hash, String, …) |
| `rbi/stdlib/` | `.rbi` | Standard-library RBI definitions |

Total: 730 files, ~5 MB of Ruby/RBI source.

Typical runtimes on a development machine (opt build, 16 worker threads):

- Wall time: ~200–230 ms
- `typecheck` phase: ~85–100 ms
- `resolving` phase: ~25–35 ms

These numbers are stable enough for before/after comparisons; expect ±5–10% noise on a shared
machine and ±1–2% on a dedicated one.

## Harness outputs

For each run, `scripts/perf-compare.sh <label> <outdir>` emits three artifacts into `<outdir>`:

| File | Technique | Contents |
|------|-----------|----------|
| `<label>.perf` | C | `perf stat -r N` output: instruction count and cycles with stddev. Falls back to a `perf unavailable` marker when `perf` cannot read hardware counters. |
| `<label>.json` | B, D | `--metrics-file` JSON: counters (input file/method/sig counts) and `run.utilization` (user/system CPU time). |
| `<label>.counters` | A, D | `--counters` stderr: phase-timer histograms (`typecheck.value`, `resolving.value`, `wall_time.value`, `indexOne.*`, etc.). |

Important: **phase timers come from `--counters`, not from `--metrics-file`.** The `--metrics-file`
JSON only carries counters and `run.utilization` CPU time — it contains no per-phase timers. Any
timer-based evidence (Technique A phase-timer curves, Technique D latency) must be read from the
`.counters` file. `scripts/perf-diff.sh` parses all three artifacts and prints a combined
before/after/delta table.

The `--counters` run occasionally hits a rare SIGSEGV on this large multi-file input (a pre-existing
Sorbet non-determinism, not introduced by the harness); `perf-compare.sh` retries it until the
histogram block is emitted.

## Selection rationale

`test/testdata/infer/` is the most type-checking-heavy input available in-tree (435 files, many
with `# typed: true` or `# typed: strict` sigils). Adding `cfg/`, `core/`, and `namer/` brings
the total above 500 non-RBI files without causing sorbet to crash (unlike some combinations that
trigger assertion failures with conflicting multi-file definitions). The `rbi/` files supply the
core type signatures that many test files depend on.

Combinations that were tested and rejected:
- `test/testdata/resolver/` combined with infer files crashes sorbet (SIGSEGV) due to conflicting
  multi-file constant definitions.
- All 2,800+ `test/testdata/` `.rb` files crashes with signal 139.

## N-sweep mode

See `scripts/perf-compare.sh` for the `FIXTURE_GEN` / sweep mode that runs sorbet on a
synthetically generated fixture at N = 10/50/100/200/400 classes and records the `typecheck`
phase timer at each N.
