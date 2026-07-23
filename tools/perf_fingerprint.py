#!/usr/bin/env python3
"""Spine parity fingerprint from callgrind output.

Answers two questions about zfish vs upstream on an identical tree, without touching
either program: are we running the SAME ALGORITHM (`calls`), and does it cost the same
(`costs`)?

WHY `calls` IS THE PARITY TEST. Call counts are inlining-immune: whatever either
compiler chose to inline, a function that is still a symbol was entered exactly as often
as the algorithm demands. On an identical tree, identical call counts prove identical
call sequence -- which is what "zfish runs Stockfish's algorithm" means operationally.
Cost ratios cannot prove it (they move with codegen); node counts cannot (they only
prove the same RESULT). Upstream's templates split one logical function into several
symbols (update_piece_threats<true>/<false>), so sum the group before comparing.

WHY `costs` AGGREGATES BY FUNCTION ACROSS ORIGIN FILES -- READ THIS BEFORE TRUSTING ANY
RATIO. callgrind emits one entry per (origin-file, function) PAIR: inlined code is
attributed to the file it CAME FROM, under the CALLER's name. So a single logical
function appears as MANY lines and its true cost is the SUM over all origin files. C++
is hit far harder than Zig here because upstream's work lives in headers. Reading one
line per side is how a real 0.99x parity gets misreported as "1.87x, the worst
component" -- that exact error was made against this codebase. This tool sums the group
and then RECONCILES the total against callgrind's own PROGRAM TOTALS; a large shortfall
means entries are being dropped and every derived ratio is fiction, so it fails loudly
rather than printing a plausible lie.

Needs no instrumentation: callgrind runs the shipped ReleaseFast artifact.

Usage:
  perf_fingerprint.py costs <callgrind.out> [--top N]
  perf_fingerprint.py calls <callgrind.out> [--match REGEX]
  perf_fingerprint.py compare <zfish.out> <upstream.out> --group NAME=REGEX[,NAME=REGEX...]
                              [--calls]

  # one logical component per --group; the REGEX may match several symbols and they are summed
  perf_fingerprint.py compare zf.out sf.out \
      --group threats='updatePieceThreats|update_piece_threats' \
      --group movepick='scoreList|nextMove|next_move'
"""

import argparse
import re
import subprocess
import sys

# "  1,234,567 (12.34%)  path/file.zig:some.function [/path/to/binary]"
_LINE = re.compile(r"^\s*([\d,]+)\s+\([\s\d.]+%\)\s+(\S+?):(.+?)(?:\s+\[[^\]]*\])?\s*$")
_TOTALS = re.compile(r"^\s*([\d,]+)\s+\([\s\d.]+%\)\s+PROGRAM TOTALS\s*$")


def _annotate(path, show="Ir"):
    try:
        r = subprocess.run(
            ["callgrind_annotate", f"--show={show}", "--threshold=99.99", path],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        sys.exit("error: callgrind_annotate not found (install valgrind)")
    except subprocess.CalledProcessError as e:
        sys.exit(f"error: callgrind_annotate failed on {path}: {e.stderr.strip()}")
    return r.stdout


def costs(path):
    """Ir per function, summed over every origin file. Returns (dict, program_total)."""
    out = _annotate(path)
    per_fn, total = {}, None
    for line in out.split("\n"):
        m = _TOTALS.match(line)
        if m:
            total = int(m.group(1).replace(",", ""))
            continue
        m = _LINE.match(line)
        if not m:
            continue
        fn = m.group(3).strip()
        if fn == "PROGRAM TOTALS" or fn.startswith("???"):
            continue
        per_fn[fn] = per_fn.get(fn, 0) + int(m.group(1).replace(",", ""))
    if total is None:
        sys.exit(f"error: no PROGRAM TOTALS in {path}; is it a callgrind output file?")
    return per_fn, total


def _reconcile(per_fn, total, path):
    """Guard the attribution trap: the per-function sum must account for the program."""
    s = sum(per_fn.values())
    miss = 1.0 - (s / total) if total else 1.0
    if miss > 0.05:
        sys.exit(
            f"error: per-function sum {s:,} accounts for only {100 * s / total:.1f}% of "
            f"PROGRAM TOTALS {total:,} in {path}.\n"
            "       Entries are being dropped -- every ratio derived from this would be "
            "fiction. Fix the parser before trusting output."
        )
    return s


def calls(path):
    """Call counts per callee, parsed from the raw callgrind file (not annotate)."""
    names, per_fn, callee = {}, {}, None
    with open(path, errors="ignore") as fh:
        for line in fh:
            line = line.rstrip("\n")
            m = re.match(r"^(c?fn)=\((\d+)\)(?:\s+(.*))?$", line)
            if m:
                if m.group(3):
                    names[m.group(2)] = m.group(3)
                callee = names.get(m.group(2)) if m.group(1) == "cfn" else callee
                continue
            if line.startswith("calls=") and callee:
                n = int(line.split("=", 1)[1].split()[0])
                per_fn[callee] = per_fn.get(callee, 0) + n
    return per_fn


def _sum_group(per_fn, pattern):
    rx = re.compile(pattern)
    hits = {fn: v for fn, v in per_fn.items() if rx.search(fn)}
    return sum(hits.values()), hits


def main():
    ap = argparse.ArgumentParser(add_help=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("costs")
    p.add_argument("out")
    p.add_argument("--top", type=int, default=20)

    p = sub.add_parser("calls")
    p.add_argument("out")
    p.add_argument("--match", default=".")

    p = sub.add_parser("compare")
    p.add_argument("zfish")
    p.add_argument("upstream")
    p.add_argument(
        "--group",
        action="append",
        required=True,
        help="NAME=REGEX; regex may match several symbols, which are summed",
    )
    p.add_argument(
        "--calls",
        action="store_true",
        help="compare CALL COUNTS (the algorithm-parity test) instead of Ir",
    )

    a = ap.parse_args()

    if a.cmd == "costs":
        per_fn, total = costs(a.out)
        s = _reconcile(per_fn, total, a.out)
        for fn, ir in sorted(per_fn.items(), key=lambda kv: -kv[1])[: a.top]:
            print(f"{ir:14,d}  ({100 * ir / total:5.2f}%)  {fn[:76]}")
        print(f"{s:14,d}  == summed;  {total:,} PROGRAM TOTALS ({100 * s / total:.1f}% accounted)")
        return

    if a.cmd == "calls":
        per_fn = calls(a.out)
        rx = re.compile(a.match)
        for fn, c in sorted(per_fn.items(), key=lambda kv: -kv[1]):
            if rx.search(fn):
                print(f"{c:12,d}  {fn[:76]}")
        return

    groups = []
    for g in a.group:
        if "=" not in g:
            sys.exit(f"error: --group wants NAME=REGEX, got {g!r}")
        name, _, rx = g.partition("=")
        groups.append((name, rx))

    if a.calls:
        zf, sf = calls(a.zfish), calls(a.upstream)
        zt = st = None
        label = "calls"
    else:
        zf, zt = costs(a.zfish)
        sf, st = costs(a.upstream)
        _reconcile(zf, zt, a.zfish)
        _reconcile(sf, st, a.upstream)
        label = "Ir"

    print(f"{'component':<22}{'zfish':>16}{'upstream':>16}{'zf/up':>9}")
    print("-" * 63)
    for name, rx in groups:
        z, _ = _sum_group(zf, rx)
        s, _ = _sum_group(sf, rx)
        if z == 0 and s == 0:
            print(f"{name:<22}{'-- no symbol matched either side --':>41}")
            continue
        ratio = (z / s) if s else float("inf")
        mark = ""
        if a.calls:
            mark = "  EXACT" if z == s else "  <-- DIFFERS: not the same call sequence"
        print(f"{name:<22}{z:>16,}{s:>16,}{ratio:>9.3f}{mark}")
    # Narrow on the totals themselves (None exactly when --calls ran): same runtime
    # behaviour as `if not a.calls`, and the type checker can see the division is safe.
    if zt is not None and st is not None:
        print("-" * 63)
        print(f"{'TOTAL':<22}{zt:>16,}{st:>16,}{zt / st:>9.3f}")
        print(
            f"\n({label} summed across all origin files; see this file's docstring "
            "for why one line per side is a lie.)"
        )


if __name__ == "__main__":
    main()
