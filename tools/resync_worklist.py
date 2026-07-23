#!/usr/bin/env python3
"""Emit the re-port worklist for an upstream pin advance.

Diff upstream between two pins (this repo's own upstream git objects -- no
sibling checkout), join every changed file through BOTH correspondence maps,
and rank by churn. The three legs of the reflexion model:

  CHANGE     changed upstream file with owners -> the re-port list
  ABSENCE    changed/new upstream file with NO owner and no exception ->
             new surface nobody would have routed
  DIVERGENCE handled by upstream_map_derive.py --audit (rot/drift), run it too

Owners come from the DERIVED map (comment citations, upstream_map_derive.py);
the DECLARED map (tools/upstream/upstream_map.tsv) contributes the risk tier
so the output slots into the same triage the router uses. A file whose derived
and declared owners disagree is marked drift=+N -- re-read the declared rule
while porting.

Usage:
  resync_worklist.py                     UPSTREAM_BASE -> UPSTREAM_TARGET
  resync_worklist.py <shaA> <shaB>       any two upstream SHAs
"""

from __future__ import annotations

import fnmatch
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import upstream_map_derive as umd  # noqa: E402


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, cwd=REPO, check=True, capture_output=True, text=True).stdout


def main() -> None:
    if len(sys.argv) == 3:
        sha_a, sha_b = sys.argv[1], sys.argv[2]
    else:
        sha_a = (REPO / "tools" / "upstream" / "UPSTREAM_BASE").read_text().strip()
        sha_b = (REPO / "tools" / "upstream" / "UPSTREAM_TARGET").read_text().strip()
    if run(["git", "rev-parse", sha_a]).strip() == run(["git", "rev-parse", sha_b]).strip():
        print(f"pins identical ({sha_a[:9]}) -- nothing to resync")
        return

    numstat = run(["git", "diff", "--numstat", sha_a, sha_b, "--", "src/"])
    mapped, _, _ = umd.build_map()
    excused = umd.exceptions()
    rules = umd.declared_rules()

    def declared_for(path: str) -> tuple[set[str], str]:
        for glob, owners in rules:
            if fnmatch.fnmatch(path, glob):
                return {o for o in owners if o}, glob
        return set(), ""

    rows = []
    absent = []
    for line in numstat.splitlines():
        add_s, del_s, path = line.split("\t", 2)
        if not path.endswith((".cpp", ".h")):
            continue
        churn = (0 if add_s == "-" else int(add_s)) + (0 if del_s == "-" else int(del_s))
        derived = set(mapped.get(path, {}))
        declared, glob = declared_for(path)
        if not derived and not declared and path not in excused:
            absent.append((churn, path))
            continue
        drift = len(derived - declared) if declared else 0
        rows.append((churn, path, sorted(derived | declared), drift))

    print(f"resync worklist {sha_a[:9]} -> {sha_b[:9]} ({len(rows)} owned, {len(absent)} unowned)\n")
    for churn, path, owners, drift in sorted(rows, reverse=True):
        mark = f"  drift=+{drift}" if drift else ""
        print(f"{churn:6d}  {path}{mark}")
        for o in owners:
            print(f"        {o}")
    if absent:
        print("\nABSENCE -- changed upstream surface with NO owner and no exception:")
        for churn, path in sorted(absent, reverse=True):
            print(f"{churn:6d}  {path}")


if __name__ == "__main__":
    main()
