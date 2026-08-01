#!/usr/bin/env bash
# Oracle adjudication for the parity goldens.
#
# A golden is a photograph of ourselves, so `<gate>-update` on a red gate pins whatever the
# binary currently does -- including a bug. AGENTS.md's rule is "drive the oracle, match its
# bytes", and every gate below turns out to be answerable by the pristine upstream binary:
# each golden is built from UCI-observable behaviour, and parity_harness takes the engine as
# an argument, so the SAME builder can be pointed at upstream's own build.
#
# So this runs each golden's check with the ORACLE as the engine. A gate that passes means
# our golden equals what upstream produces -- the reharden is proven, not self-blessed. A
# gate that fails is either a real divergence or a rig problem (see CWD below); it is never
# something to regenerate past.
#
# Usage:
#   upstream_golden_audit.sh                # audit every gate
#   upstream_golden_audit.sh search-parity tb-search    # audit only these
#   upstream_golden_audit.sh --list         # print the gate list and exit
#   ORACLE_SHA=<sha>                        # adjudicate against another commit
#
# CWD MATTERS, and getting it wrong reads as a divergence. Every gate runs from the repo's
# resources/ -- that is where the net lives AND where syzygy/ + syzygy5/ are fetched. Run the
# oracle from its own worktree instead and `SyzygyPath value syzygy` resolves to upstream's
# SOURCE directory (src/syzygy/tbprobe.cpp), no tablebase loads, and tb-search reports
# with-tb == no-tb on every row. That is not a divergence; it is a rig with no tablebases.
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
RESOURCES="$REPO/resources"

# gate:golden-basename. The golden's file name does not always match its gate name, so pair
# them explicitly rather than transforming one into the other.
GATES=(
    "search-parity:search_parity"
    "search-modes:search_modes"
    "output-golden:output_parity"
    "driver-golden:driver"
    "eval:eval"
    "misc:misc"
    "mate:mate"
    "perft:perft"
    "fen-errors:fen_errors"
    "chess960:chess960"
    "nodestime:nodestime"
    "uci-options:uci_options"
    "export-net:export_net"
    "bench-matrix:bench_matrix"
    "mt-sanity:mt_sanity"
    "tb-init:tb_init"
    "tb-wdl:tb_wdl"
    "tb-dtz:tb_dtz"
    "tb-root:tb_root"
    "tb-search:tb_search"
    "tb-cursed:tb_cursed"
)

if [ "${1:-}" = "--list" ]; then
    for g in "${GATES[@]}"; do echo "${g%%:*}"; done
    exit 0
fi

# Keep only the gates named on the command line, if any.
if [ "$#" -gt 0 ]; then
    WANTED=()
    for want in "$@"; do
        hit=0
        for g in "${GATES[@]}"; do
            [ "${g%%:*}" = "$want" ] && { WANTED+=("$g"); hit=1; }
        done
        [ "$hit" = 0 ] && { echo "golden-audit: unknown gate '$want' (see --list)" >&2; exit 2; }
    done
    GATES=("${WANTED[@]}")
fi

ORACLE_BIN="$("$REPO/tools/upstream_oracle.sh" ${ORACLE_SHA:+"$ORACLE_SHA"})" \
    || { echo "golden-audit: oracle build failed" >&2; exit 2; }

# parity_harness is a build artifact; build it the same way the gates do, then find it.
zig build --build-file "$REPO/build.zig" parity-harness >/dev/null 2>&1 || true
HARNESS="$(find "$REPO/.zig-cache/o" -name parity_harness -type f -newer "$REPO/tools/parity_harness.zig" 2>/dev/null | head -1)"
[ -z "$HARNESS" ] && HARNESS="$(find "$REPO/.zig-cache/o" -name parity_harness -type f 2>/dev/null | head -1)"
[ -z "$HARNESS" ] && { echo "golden-audit: no parity_harness in .zig-cache -- run 'zig build parity' once first" >&2; exit 2; }

echo "golden-audit: adjudicating $(printf '%s' "${#GATES[@]}") golden(s) against $ORACLE_BIN"
echo "golden-audit: cwd = $RESOURCES (net + syzygy/ + syzygy5/ must resolve from here)"
echo ""

agree=0
differ=0
skipped=0
FAILED=()
for entry in "${GATES[@]}"; do
    gate="${entry%%:*}"
    golden="$REPO/tools/${entry##*:}.golden"
    printf '  %-16s ' "$gate"
    if [ ! -f "$golden" ]; then
        echo "SKIP (no $golden)"
        skipped=$((skipped + 1))
        continue
    fi
    out="$( cd "$RESOURCES" && "$HARNESS" "$gate" "$ORACLE_BIN" "$golden" check 2>&1 )"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "AGREES"
        agree=$((agree + 1))
    else
        echo "DIFFERS (rc=$rc)"
        printf '%s\n' "$out" | head -8 | sed 's/^/      | /'
        differ=$((differ + 1))
        FAILED+=("$gate")
    fi
done

echo ""
echo "golden-audit: $agree agree, $differ differ, $skipped skipped"
if [ "$differ" -gt 0 ]; then
    echo "golden-audit: NOT adjudicated: ${FAILED[*]}" >&2
    echo "golden-audit: do NOT run <gate>-update on these -- a golden blessed past a real" >&2
    echo "golden-audit: divergence pins the divergence. Find out why upstream disagrees first." >&2
    exit 1
fi
echo "golden-audit: OK -- every golden matches what upstream itself produces"
exit 0
