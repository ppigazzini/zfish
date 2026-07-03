#!/usr/bin/env bash
# Per-position search-fingerprint differential harness (M5).
#
# Runs the engine's own `bench` (TT shared across positions, the exact
# semantics the signature gate measures) and extracts, for each of the 51
# bench positions, a stable fingerprint: final search depth, score, the
# position's cumulative node count, and the chosen bestmove. The per-position
# node counts sum to the bench signature, so this turns a whole-bench
# signature mismatch into a single pinpointed position + the field that drifted.
#
# Usage:
#   search_parity.sh <stockfish-bin> <golden-file> [check|update]
#     check  (default): diff the live fingerprint against <golden-file>;
#                        exit non-zero on the first divergence.
#     update          : (re)write <golden-file> from the live run.
#
# Run with cwd = src/ so the external NNUE net resolves.
set -u

BIN="$1"
GOLDEN="$2"
MODE="${3:-check}"

raw="$(printf 'bench\nquit\n' | "$BIN" bench 2>&1)" || {
    echo "search-parity: engine run failed" >&2
    exit 2
}

# Reduce the bench transcript to one fingerprint line per position plus a TOTAL.
fingerprint() {
    awk '
    /^Position: / { pos = $2 }                 # field 2 is "N/51"
    /^info depth / { last = $0 }               # keep the deepest info line
    /^bestmove / {
        bm = $2
        n = split(last, a, " ")
        d = ""; nd = ""; sc = ""
        for (i = 1; i <= n; i++) {
            if (a[i] == "depth") d  = a[i + 1]
            if (a[i] == "nodes") nd = a[i + 1]
            if (a[i] == "score") sc = a[i + 1] " " a[i + 2]
        }
        printf "%-6s depth=%-3s score=%-9s nodes=%-9s bestmove=%s\n", pos, d, sc, nd, bm
        last = ""
    }
    /^Nodes searched/ { printf "TOTAL nodes=%s\n", $NF }
    '
}

live="$(printf '%s\n' "$raw" | fingerprint)"

if [ -z "$live" ] || ! printf '%s\n' "$live" | grep -q '^TOTAL '; then
    echo "search-parity: could not parse bench output (engine crashed?)" >&2
    printf '%s\n' "$raw" | tail -5 >&2
    exit 2
fi

if [ "$MODE" = "update" ]; then
    printf '%s\n' "$live" > "$GOLDEN"
    echo "search-parity: wrote golden ($(printf '%s\n' "$live" | grep -c '^[0-9]') positions)"
    printf '%s\n' "$live" | grep '^TOTAL '
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "search-parity: golden file missing: $GOLDEN (run the update step first)" >&2
    exit 2
fi

if diff_out="$(diff <(cat "$GOLDEN") <(printf '%s\n' "$live"))"; then
    echo "search-parity: OK ($(printf '%s\n' "$live" | grep -c '^[0-9]') positions match golden)"
    printf '%s\n' "$live" | grep '^TOTAL '
    exit 0
fi

echo "search-parity: MISMATCH vs golden (< golden, > live):" >&2
printf '%s\n' "$diff_out" >&2
exit 1
