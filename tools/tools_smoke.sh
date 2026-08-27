#!/usr/bin/env bash
# tools-smoke: assert the tools NO LANE INVOKES still run and still present their interface.
#
# `lane-coverage` asks "does anything dispatch this build step?". This asks the same question
# one level down, for the tools that are not build steps at all: a tool no workflow, no build
# step and no other tool ever calls rots exactly like a lane in no gate, and it rots silently
# -- it sits in tools/ looking maintained.
#
# THE PREDICTION WAS TESTED BEFORE THIS FILE EXISTED, and one of the six had rotted:
# `upstream_net.sh` was copying 91 MB into every worktree's `src/`, the location the net left
# when zfish moved to loading it from `resources/`. The copy was useless AND the problem the
# tool exists to solve was untouched, for as long as nobody happened to run it (353539e2).
#
# WHAT A ROW ASSERTS, and what it deliberately does not. Each row runs the tool the cheapest
# way that still executes its real code path, and checks the EXIT CODE plus a string its
# callers actually read. That catches the class that bites here -- a tool that no longer runs,
# no longer parses the tree, or no longer prints the interface a caller greps. It does NOT
# check that the tool's ANSWER is right; that is the job of the gate the tool serves, and a
# smoke test claiming more than it does is the failure one level up.
#
# A USAGE REFUSAL IS A PASS, and it must be asserted as one. `nps_ab.sh` with no arguments
# exits non-zero on purpose, so a row that merely required exit 0 would report that tool as
# broken, and a row that ignored the exit code would pass over a tool that had stopped running
# entirely. Each row states the exit code it expects.
#
# Usage:  tools/tools_smoke.sh
# Exit:   0 every tool ran and printed its interface, 1 one did not, 2 a rig fault.
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
# A failed cd would run every tool from the caller's directory instead of the repo.
cd "$REPO" || exit 2

TIMEOUT="${SMOKE_TIMEOUT:-300}"

pass=0; bad=0; ran=0

# Run one tool and hold it to an expected exit code and an expected string.
#   smoke <label> <expect-exit> <expect-substring> -- <command...>
smoke() {
    local label="$1" want_rc="$2" want_txt="$3"; shift 4  # the 4th is the literal `--`
    local out rc
    out="$(timeout "$TIMEOUT" "$@" 2>&1)"; rc=$?
    ran=$((ran + 1))

    if [ "$rc" -eq 124 ]; then
        printf '  RIG   %-24s did not finish in %ss\n' "$label" "$TIMEOUT"
        bad=$((bad + 1)); return
    fi
    if [ "$rc" -ne "$want_rc" ]; then
        printf '  FAIL  %-24s exit %d, expected %d\n' "$label" "$rc" "$want_rc"
        printf '%s\n' "$out" | sed 's/^/          /' | head -6
        bad=$((bad + 1)); return
    fi
    if ! printf '%s\n' "$out" | grep -qF -- "$want_txt"; then
        printf '  FAIL  %-24s ran, but no longer prints the interface its callers read\n' "$label"
        printf '        expected to find: %s\n' "$want_txt"
        printf '%s\n' "$out" | sed 's/^/          /' | head -6
        bad=$((bad + 1)); return
    fi
    printf '  ok    %-24s exit %d, interface intact\n' "$label" "$rc"
    pass=$((pass + 1))
}

printf 'tools-smoke: the tools no workflow, no build step and no other tool invokes\n'

# Refuses without arguments, and the usage line is the interface -- every caller of this tool
# is a human reading it. Needs nothing: no oracle, no engine, no upstream objects.
smoke "nps_ab.sh" 1 "usage: nps_ab.sh" -- bash tools/nps_ab.sh

# The warm-game axis. Two rows, because the pair has two independent failure modes and the
# driver is the half that rots: ltc_ab.sh refuses without binaries, and ltc_replay.py must
# still PARSE and present its modes -- a driver that stopped accepting `startup` would leave
# the A/B silently comparing raw totals with no floor subtracted.
smoke "ltc_ab.sh" 2 "Paired A/B in the regime" -- bash tools/ltc_ab.sh
smoke "ltc_replay.py" 0 "record,replay,startup,clock" -- python3 tools/ltc_replay.py --help

# Reads the pin pair out of this repo's own git objects and reports the re-port plan. Its
# output shape is what a resync reads, so the "nothing to resync" / worklist line is the
# interface. Needs the upstream objects, which a plain origin checkout does not carry.
smoke "resync_worklist.py" 0 "resync" -- python3 tools/resync_worklist.py

# One line per commit over UPSTREAM_BASE..UPSTREAM_TARGET with its routing class. The tally
# line is what a porter reads; an empty backlog still prints it, which is the point -- the
# tool must be distinguishable from a tool that printed nothing.
smoke "upstream_router.py" 0 "backlog:" -- python3 tools/upstream_router.py --backlog

# Emits <short-sha> <bench> <subject> over the pin range. The HEADER is the interface: a
# consumer reads columns, and a header that stopped matching means the columns moved.
smoke "upstream_benchmap.sh" 0 "SHA" -- bash tools/upstream_benchmap.sh

# perf_callgrind_delta.py. THE REFUSALS ARE THE TOOL, so they are what gets smoked: it
# subtracts startup from two engines' profiles, and every refusal below guards a way the
# subtraction can be quoted over numbers that do not mean what the reader thinks. Running
# it for real needs valgrind, two built engines and ~50x slowdown; synthetic profiles
# exercise the same parse and the same guards in milliseconds.
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
_profile() {  # _profile <path> <Ir> ; a callgrind summary is events: + summary:
    printf 'events: Ir Dr Dw I1mr D1mr D1mw ILmr DLmr DLmw Bc Bcm Bi Bim\n' > "$1"
    printf 'summary: %d 100 50 5 20 10 1 2 3 400 40 30 3\n' "$2" >> "$1"
}
_profile "$FIX/a_deep.out" 1000; printf '2497913\n' > "$FIX/a_deep.out.nodes"
_profile "$FIX/a_shal.out"  100; printf '19\n'      > "$FIX/a_shal.out.nodes"
_profile "$FIX/b_deep.out" 2000; printf '2497913\n' > "$FIX/b_deep.out.nodes"
_profile "$FIX/b_shal.out"  200; printf '19\n'      > "$FIX/b_shal.out.nodes"

smoke "perf_callgrind_delta" 1 "Usage" -- python3 tools/perf_callgrind_delta.py

smoke "  ^ refuses no sidecar" 1 "re-run perf_callgrind.sh" -- \
    python3 tools/perf_callgrind_delta.py "$FIX/a_deep.out" "$FIX/a_shal.out" \
    "$FIX/b_deep.out" "$FIX/nope.out"

_profile "$FIX/b_wrong.out" 2000; printf '999999\n' > "$FIX/b_wrong.out.nodes"
smoke "  ^ refuses a differing tree" 1 "not the same workload" -- \
    python3 tools/perf_callgrind_delta.py "$FIX/a_deep.out" "$FIX/a_shal.out" \
    "$FIX/b_wrong.out" "$FIX/b_shal.out"

printf 'events: Ir\n' > "$FIX/b_dead.out"; printf '2497913\n' > "$FIX/b_dead.out.nodes"
smoke "  ^ refuses a dead run" 1 "did the run die?" -- \
    python3 tools/perf_callgrind_delta.py "$FIX/a_deep.out" "$FIX/a_shal.out" \
    "$FIX/b_dead.out" "$FIX/b_shal.out"

smoke "  ^ subtracts when valid" 0 "startup-subtracted" -- \
    python3 tools/perf_callgrind_delta.py "$FIX/a_deep.out" "$FIX/a_shal.out" \
    "$FIX/b_deep.out" "$FIX/b_shal.out"

if [ "$ran" -eq 0 ]; then
    printf 'tools-smoke: no rows ran -- the table is empty and this would report OK over\n'
    printf 'tools-smoke: nothing. Refusing.\n' >&2
    exit 2
fi
if [ "$bad" -ne 0 ]; then
    printf 'tools-smoke: %d of %d tool(s) FAILED\n' "$bad" "$ran" >&2
    exit 1
fi
printf 'tools-smoke: %d of %d unlaned tool(s) still run and still print their interface\n' "$pass" "$ran"

# NOT COVERED, stated rather than left to be assumed -- a gate that does not name its own
# blind spot gets read as covering more than it does. Two of the six unlaned tools need the
# pristine oracle BUILT (a full upstream compile) before they do anything:
#
#   upstream_net.sh     resolves the net out of the oracle's own tree
#   upstream_nodes.sh   diffs node counts against the oracle binary
#
# They are NOT smoked, here or anywhere. A conditional row that skipped when the oracle was
# absent would report OK over a tool it never ran, which is the failure this file exists to
# prevent; and `upstream_net.sh` is precisely the tool that rotted unobserved, so a silent
# skip on it would be the same hole again. Covering them means running them for real in the
# weekly lane that already builds an oracle. Both were verified by hand at 353539e2.
