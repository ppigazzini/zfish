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
#   upstream_golden_audit.sh --skip tb-cursed           # audit every gate BUT these
#   upstream_golden_audit.sh --list         # print the gate list and exit
#   ORACLE_SHA=<sha>                        # adjudicate against another commit
#
# Prefer --skip over naming gates positionally when the reason is a MISSING FIXTURE rather
# than a narrowed run: a positional list silently stops covering every gate added after it
# was written, where --skip keeps picking new gates up. CI skips tb-cursed for exactly that
# reason -- it needs the 5-man tables, which no CI lane fetches.
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

# Reject an unknown gate name rather than quietly auditing nothing: a typo in a CI --skip
# would otherwise read as a clean run over a set that never excluded what it meant to.
known() {
    for g in "${GATES[@]}"; do [ "${g%%:*}" = "$1" ] && return 0; done
    echo "golden-audit: unknown gate '$1' (see --list)" >&2
    exit 2
}

SKIPPED_BY_REQUEST=()
WANTED=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip)
            [ "$#" -ge 2 ] || { echo "golden-audit: --skip needs a gate name" >&2; exit 2; }
            known "$2"; SKIPPED_BY_REQUEST+=("$2"); shift 2 ;;
        -*) echo "golden-audit: unknown flag '$1'" >&2; exit 2 ;;
        *)  known "$1"; WANTED+=("$1"); shift ;;
    esac
done

FILTERED=()
for g in "${GATES[@]}"; do
    gate="${g%%:*}"
    skip=0
    for s in ${SKIPPED_BY_REQUEST+"${SKIPPED_BY_REQUEST[@]}"}; do
        [ "$s" = "$gate" ] && skip=1
    done
    [ "$skip" = 1 ] && continue
    if [ "${#WANTED[@]}" -gt 0 ]; then
        keep=0
        for w in "${WANTED[@]}"; do [ "$w" = "$gate" ] && keep=1; done
        [ "$keep" = 0 ] && continue
    fi
    FILTERED+=("$g")
done
GATES=(${FILTERED+"${FILTERED[@]}"})
[ "${#GATES[@]}" -eq 0 ] && { echo "golden-audit: no gates selected" >&2; exit 2; }
# `${#arr[@]:-0}` is not a length with a default -- it is `${#arr[@]}` fed to `:-`, which
# bash rejects as a bad substitution. It printed the error and skipped the line, so a --skip
# run reported nothing about what it excluded: the one thing this echo exists to say. Take
# the array's SET-ness the same way the expansions above do.
[ "${SKIPPED_BY_REQUEST+set}" = set ] \
    && echo "golden-audit: skipping by request: ${SKIPPED_BY_REQUEST[*]}"

ORACLE_BIN="$("$REPO/tools/upstream_oracle.sh" ${ORACLE_SHA:+"$ORACLE_SHA"})" \
    || { echo "golden-audit: oracle build failed" >&2; exit 2; }

# parity_harness is a build artifact with no step of its own; `signature` is the cheapest
# step that produces it, and it also leaves resources/ holding the net every gate needs.
# `tb-init` additionally fetches the 3-man Syzygy set the tablebase gates read.
( cd "$REPO" && zig build signature tb-init ) >/dev/null 2>&1 \
    || { echo "golden-audit: 'zig build signature tb-init' failed -- fix the build first" >&2; exit 2; }

# Take the newest build, not the first `find` happens to return: .zig-cache/o keeps one
# directory per harness BUILD, so a stale binary from an older tools/parity_harness.zig sits
# there forever and would audit the goldens with the wrong builder.
HARNESS="$(find "$REPO/.zig-cache/o" -name parity_harness -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)"
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

# Read the DECLARED divergences and enforce their tags. Without this the two gates that pin
# zfish's own Zone-A fixes made the audit exit 1 forever, which is how the weekly lane came
# to be red by construction while the README called that state expected.
KNOWN_FILE="$REPO/tools/golden_audit_known.txt"
[ -r "$KNOWN_FILE" ] || {
    echo "golden-audit: cannot read $KNOWN_FILE -- the declared-divergence list is this" >&2
    echo "golden-audit: gate's only allowance; without it every declared row would read as" >&2
    echo "golden-audit: a finding. Refusing rather than guessing." >&2
    exit 2; }

declared_expiring=()
declared_permanent=()
while IFS=$'\t' read -r tag gate _reason; do
    case "$tag" in ''|\#*) continue ;; esac
    [ -n "${gate:-}" ] || continue
    known "$gate"
    case "$tag" in
        EXPIRING)  declared_expiring+=("$gate") ;;
        PERMANENT) declared_permanent+=("$gate") ;;
        *) echo "golden-audit: $KNOWN_FILE: row for '$gate' has tag '$tag'; want EXPIRING or PERMANENT" >&2
           exit 2 ;;
    esac
done < "$KNOWN_FILE"

in_list() { local n="$1"; shift; local g; for g in "$@"; do [ "$g" = "$n" ] && return 0; done; return 1; }

rc_final=0

# An UNDECLARED gate that differs is the finding this audit exists to surface.
undeclared=()
for gate in "${FAILED[@]:-}"; do
    [ -n "$gate" ] || continue
    if ! in_list "$gate" "${declared_expiring[@]:-}" "${declared_permanent[@]:-}"; then
        undeclared+=("$gate")
    fi
done
if [ "${#undeclared[@]}" -gt 0 ]; then
    echo "golden-audit: NOT adjudicated: ${undeclared[*]}" >&2
    echo "golden-audit: do NOT run <gate>-update on these -- a golden blessed past a real" >&2
    echo "golden-audit: divergence pins the divergence. Find out why upstream disagrees first." >&2
    echo "golden-audit: if it is a deliberate zfish fix, declare it in $KNOWN_FILE." >&2
    rc_final=1
fi

# An EXPIRING row that no longer differs has outlived its cause: upstream adopted the fix.
# Left in place it would go on granting an allowance for a gate the audit is no longer
# adjudicating, which is the failure this tag exists to prevent.
expired=()
for gate in "${declared_expiring[@]:-}"; do
    [ -n "$gate" ] || continue
    in_list "$gate" "${SKIPPED_BY_REQUEST[@]:-}" && continue
    in_list "$gate" "${FAILED[@]:-}" || expired+=("$gate")
done
if [ "${#expired[@]}" -gt 0 ]; then
    echo "golden-audit: EXPIRED declaration(s): ${expired[*]}" >&2
    echo "golden-audit: these are declared EXPIRING in $KNOWN_FILE but now AGREE with" >&2
    echo "golden-audit: upstream -- the gap closed. DELETE the row; leaving it grants an" >&2
    echo "golden-audit: allowance that stops this gate being adjudicated at all." >&2
    rc_final=1
fi

[ "$rc_final" -ne 0 ] && exit "$rc_final"

if [ "$differ" -gt 0 ]; then
    echo "golden-audit: OK -- every golden matches upstream except ${#FAILED[@]} DECLARED"
    echo "golden-audit: divergence(s) (${FAILED[*]}), each owned in $KNOWN_FILE"
    exit 0
fi
echo "golden-audit: OK -- every golden matches what upstream itself produces"
exit 0
