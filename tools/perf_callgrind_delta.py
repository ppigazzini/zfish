#!/usr/bin/env python3
"""Startup-subtracted, deterministic counter table from four callgrind profiles.

WHY THIS EXISTS. `perf_callgrind.sh` already simulates cache and branches, and its
own header says startup contaminates a shallow bench and must be subtracted before
quoting a search-only ratio -- and then gives you no way to do it. So the
subtraction was a manual recipe, which means in practice it was skipped and
whole-process numbers got quoted as search numbers. That is not a small error on
this pair: zfish's net parse and upstream's differ by well over a billion
instructions, all of it before the first node is searched.

WHY IT IS WORTH HAVING BESIDE `perf_counters.zig`. That tool reads HARDWARE
counters, where a cycle or miss count carries run-to-run noise comparable to the
term being removed -- the documented serial floor on this box is +/-1% with a
+0.65% A/A bias. Callgrind SIMULATES, so every axis here is deterministic per
binary and the subtraction is exact arithmetic on exact numbers. This is the only
startup-clean read of cache and branch behaviour in the tree.

WHAT IT IS NOT. The cache model is callgrind's, not this host's: a fixed two-level
configuration, no prefetcher, no SMT. Callgrind is also BLIND to software prefetch
on both engines, so no table printed here can certify a prefetch change. Ratios
between two binaries under one model are meaningful; the absolute miss counts are
not this machine's. Read the ratio, never the absolute -- and remember an
instruction win can still be a cycle LOSS (three recurrences in this repo).

Events are zipped from each profile's own `events:` line rather than read
positionally. Getting that wrong silently renames a cache row into a branch row,
which is a wrong finding that looks exactly like a right one.

Node parity is REQUIRED, not assumed: a different tree is a different workload and
every ratio would be void. `perf_callgrind.sh` writes `<out>.nodes` beside each
profile for this; a missing sidecar is an error rather than a warning.

Usage (CWD must be resources/ so both binaries find the net):
  OUT=a_deep.out tools/perf_callgrind.sh <A> 16 1 8   # deep
  OUT=a_shal.out tools/perf_callgrind.sh <A> 16 1 1   # startup
  OUT=b_deep.out tools/perf_callgrind.sh <B> 16 1 8   # deep
  OUT=b_shal.out tools/perf_callgrind.sh <B> 16 1 1   # startup
  tools/perf_callgrind_delta.py a_deep.out a_shal.out b_deep.out b_shal.out

B is the ORACLE, and the oracle is ALWAYS the zig-c++ build (see
tools/upstream_oracle.sh). A gcc-built binary measures gcc, not zfish.
"""

import sys
from pathlib import Path

# Derived rows, in reading order: work, then the two things an IPC gap can be.
DERIVED = [
    ("instructions", lambda e: e["Ir"]),
    ("data reads", lambda e: e["Dr"]),
    ("data writes", lambda e: e["Dw"]),
    ("I1 misses", lambda e: e["I1mr"]),
    ("D1 read misses", lambda e: e["D1mr"]),
    ("D1 write misses", lambda e: e["D1mw"]),
    ("LL data misses", lambda e: e["DLmr"] + e["DLmw"]),
    ("cond branches", lambda e: e["Bc"]),
    ("cond mispredicts", lambda e: e["Bcm"]),
    ("indirect branches", lambda e: e["Bi"]),
    ("indirect mispredicts", lambda e: e["Bim"]),
]


def load(path):
    """Return {event: count} from a callgrind profile's summary line."""
    events = None
    for line in Path(path).read_text().splitlines():
        if line.startswith("events:"):
            events = line.split()[1:]
        elif line.startswith("summary:"):
            if events is None:
                sys.exit(f"error: {path} has a summary line before its events line")
            counts = [int(x) for x in line.split()[1:]]
            if len(counts) != len(events):
                sys.exit(f"error: {path} has {len(counts)} counts for {len(events)} events")
            return dict(zip(events, counts, strict=True))
    sys.exit(f"error: {path} has no summary line -- did the run die?")


def nodes(path):
    """Return the node count `perf_callgrind.sh` recorded beside the profile."""
    side = Path(str(path) + ".nodes")
    if not side.is_file():
        sys.exit(f"error: {side} missing -- re-run perf_callgrind.sh to record the workload")
    text = side.read_text().strip()
    if not text.isdigit():
        sys.exit(f"error: {side} does not hold a node count")
    return int(text)


def main(a_deep, a_shal, b_deep, b_shal):
    # The workload precondition, checked on both axes before anything is printed.
    for lo, hi, what in ((a_shal, b_shal, "startup"), (a_deep, b_deep, "deep")):
        if nodes(lo) != nodes(hi):
            sys.exit(
                f"error: {what} node counts differ ({nodes(lo)} vs {nodes(hi)});"
                " the trees are not the same workload and every ratio would be void"
            )

    ad, ash = load(a_deep), load(a_shal)
    bd, bsh = load(b_deep), load(b_shal)
    dn = nodes(a_deep) - nodes(a_shal)

    print("# startup-subtracted, deterministic (callgrind sim)")
    print(f"# deep {nodes(a_deep)} nodes - startup {nodes(a_shal)} nodes = {dn} searched")
    print(f"{'axis':<22}{'A':>16}{'B':>16}{'A/B':>9}")
    print("-" * 63)
    for name, pick in DERIVED:
        a = pick(ad) - pick(ash)
        b = pick(bd) - pick(bsh)
        if b <= 0:
            print(f"{name:<22}{a:>16,}{b:>16,}{'n/a':>9}")
            continue
        print(f"{name:<22}{a:>16,}{b:>16,}{a / b:>9.3f}")

    # The mispredict RATE is the row a ratio hides: fewer branches with the same
    # absolute mispredicts is a prediction gap, and only the rate shows it.
    for label, d, s in (("A", ad, ash), ("B", bd, bsh)):
        bc, bcm = d["Bc"] - s["Bc"], d["Bcm"] - s["Bcm"]
        if bc > 0:
            print(f"# {label} conditional mispredict rate: {bcm / bc * 100:.2f}%")
    print("# ratios are model-relative: read them, never the absolute miss counts.")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:5])
