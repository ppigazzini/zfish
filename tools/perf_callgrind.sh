#!/usr/bin/env bash
# Deterministic cost measurement for one engine binary.
#
# Runs callgrind over a bench and prints instructions, data refs and D1/LL misses. Needs no
# instrumentation: it measures the shipped ReleaseFast artifact, so zfish and an upstream
# binary are directly comparable when handed the same bench (same node count => same tree =>
# same workload).
#
# WHY THIS AND NOT nps, for anything under ~5%: callgrind counts are DETERMINISTIC. Wall-clock
# on this hardware has been observed swinging 48% across interleaved rounds -- enough that a
# real -0.72% win was once "measured" as -0.2% noise and wrongly recorded as falsified, and a
# change worth 0.011% looked like +6%. If a hypothesis is worth less than a few percent, nps
# CANNOT settle it and callgrind can (it resolves 0.01%). Use nps only for the headline ratio,
# and only via nps_ab.sh.
#
# Instruction counts alone do not predict time -- zfish has measured BETTER cache hit rates and
# far fewer branches than upstream while still being slower -- so D refs and misses are printed
# alongside: a gap in time with no gap in Ir is a memory-traffic or IPC gap, not extra work.
#
# Startup contaminates a shallow bench (net load, magic init and the startup fills are ~1.4-1.7 GB
# of the refs here). Subtract it before quoting a search-only ratio; perf_fingerprint.py costs
# will show the offenders by name.
#
# Usage: perf_callgrind.sh <binary> [bench-args...]     (CWD must be resources/ so the net loads)
#        OUT=path/to.out perf_callgrind.sh ./stockfish 16 1 11
#
# Pass bench ARGS ONLY -- this script prepends `bench` itself. Passing `bench`
# again makes the engine parse it as a filename, exit early, and produce a
# plausible-looking STARTUP-ONLY profile (the mcfish twin of this script caught
# exactly that failure).
set -u

BIN="${1:?usage: perf_callgrind.sh <binary> [bench-args...]  (run with CWD=resources/)}"
shift
BENCH_ARGS=("${@:-16 1 11}")
OUT="${OUT:-callgrind.out}"

command -v valgrind >/dev/null || { echo "error: valgrind not installed" >&2; exit 1; }
[ -x "$BIN" ] || { echo "error: $BIN is not executable" >&2; exit 1; }

echo "# callgrind: $BIN bench ${BENCH_ARGS[*]}  -> $OUT"
valgrind --tool=callgrind --callgrind-out-file="$OUT" --cache-sim=yes --branch-sim=yes \
  "$BIN" bench ${BENCH_ARGS[*]} 2>&1 |
  grep -E "Nodes searched|I   refs|D   refs|D1  misses|LLd misses|D1  miss rate|Branches|Mispredicts"

echo
echo "# node count above MUST match the other engine's, or the trees differ and every"
echo "# comparison below is void. Per-function breakdown:"
echo "#   tools/perf_fingerprint.py costs $OUT"
echo "#   tools/perf_fingerprint.py compare $OUT <upstream.out> --group name=REGEX --calls"
