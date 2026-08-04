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
cd "$REPO"

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
