#!/usr/bin/env bash
# God-file structural gate.
#
# The invariant: no repo-owned .zig file should grow into a god-file. An earlier decomposition
# reached "0 files >= 500 lines"; later-grown files (the Syzygy prober wdl.zig, the session
# facade engine.zig) re-crossed it, and nothing gated the property -- so it drifted back. This
# is that gate. Both were since split back under the line; the remaining waived files are the
# build script and the parity harness (cohesive-not-god).
#
# It counts .zig files with >= LOC_THRESHOLD (default 500) lines and ratchets like
# the headless gate: LOC_BASELINE is the currently-allowed count; the gate FAILS if
# the real count exceeds it (a new god-file appeared or one grew past the line),
# and NUDGES if it drops (lower the baseline). Waiving the current large files (each
# is one cohesive subsystem, not a true god-file -- splitting a cohesive file into
# coupled micro-files is the R6 barnacle anti-pattern) while forbidding new ones is
# the intended steady state; target 0 only if a clean split emerges.
#
# Usage: loc_lint.sh
#        LOC_BASELINE=N LOC_THRESHOLD=500 loc_lint.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLD="${LOC_THRESHOLD:-500}"
BASELINE="${LOC_BASELINE:-2}"
# (build.zig passes LOC_BASELINE; the default here matches the current waived set:
#  build.zig + tools/parity_harness.zig.)

count=0
tmp="$(mktemp)"
# Scan every repo-owned .zig -- src/ (runtime) AND build.zig + tools/ (the build script and
# harness). A src/-only scan is a blind spot: build.zig is the repo's largest file, and the
# "no god-files" property is dishonest if the gate cannot see it.
while IFS= read -r f; do
    n=$(wc -l < "$f")
    if [ "$n" -ge "$THRESHOLD" ]; then
        printf '  %5d  %s\n' "$n" "${f#"$ROOT"/}" >> "$tmp"
        count=$((count + 1))
    fi
done < <({ find "$ROOT/src" "$ROOT/tools" -name '*.zig'; [ -f "$ROOT/build.zig" ] && echo "$ROOT/build.zig"; } | sort)

if [ "$count" -gt 0 ]; then
    echo "loc: files >= $THRESHOLD lines:"
    sort -rn "$tmp"
fi
rm -f "$tmp"
echo "loc: $count file(s) >= $THRESHOLD lines (baseline $BASELINE)"

if [ "$count" -gt "$BASELINE" ]; then
    echo "loc: REGRESSION -- a new god-file crossed $THRESHOLD lines (split it, or justify + raise LOC_BASELINE)." >&2
    exit 1
fi
if [ "$count" -lt "$BASELINE" ]; then
    echo "loc: NUDGE -- $count < baseline $BASELINE; lower LOC_BASELINE (a god-file was split)."
fi
if [ "$count" -eq 0 ]; then
    echo "loc: OK -- no file >= $THRESHOLD lines (god-file split holds)"
fi
exit 0
