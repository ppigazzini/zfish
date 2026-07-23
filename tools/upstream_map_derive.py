#!/usr/bin/env python3
"""Derive the upstream<->zfish file correspondence from source comments, and
audit the declared blast-radius map against it.

WHY COMMENTS. zfish renames its symbols freely, so a symbol-table join has
nothing to join on. What the tree carries -- enforced by the writing rules --
is the upstream-citation convention: every ported mechanism cites its upstream
file ("search.cpp:642", "upstream position.cpp:1038", "(nnue_common.h:200)").
zfish ships no C or C++ of its own, so EVERY ".cpp" or ".h" citation is
unambiguously upstream -- simpler than the sibling port this adapts
(mcfish tools/upstream_map.py, itself adapting z47's correspondence manifest).

THE JOIN. For every tracked src/ file, collect upstream citations:
  - any ".cpp" name, with or without :line
  - any ".h" name with a :line, OR on a line that also says upstream/golden/
    Stockfish/SF (bare .h names without context stay uncounted: too many
    generic words end in .h inside prose)
Basenames resolve to full paths in the pinned upstream tree, read from THIS
repo's own git objects at tools/upstream/UPSTREAM_TARGET (no sibling checkout
needed). Upstream files not applicable by design carry a reason in
tools/upstream/upstream_map.exceptions and count as covered.

OUTPUTS
  - the derived map   upstream path -> owning zfish files, weighted by citations
  - uncovered         upstream files nothing cites: unported or unannotated
  - phantoms          citations naming files absent at the pin: drift or typos
  - declared-map audit (--audit): rows of tools/upstream/upstream_map.tsv whose
    owner files do not exist in the tree (rot), and derived owners the declared
    glob for that upstream file does not list (drift). The declared map is the
    ROUTER's risk model; this report is what keeps it honest.

Usage:
  upstream_map_derive.py            print the full derived map as TSV
  upstream_map_derive.py --check    coverage summary + gap lists only
  upstream_map_derive.py --audit    declared-map rot/drift report
"""

from __future__ import annotations

import argparse
import fnmatch
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PIN_FILE = REPO / "tools" / "upstream" / "UPSTREAM_TARGET"
DECLARED = REPO / "tools" / "upstream" / "upstream_map.tsv"
EXCEPTIONS = REPO / "tools" / "upstream" / "upstream_map.exceptions"
BASELINE = REPO / "tools" / "upstream" / "upstream_map.baseline"

CPP_REF = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*\.cpp)(?::\d+)?\b")
H_LINE_REF = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*\.h):\d+\b")
H_CTX_REF = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*\.h)\b")
CONTEXT = re.compile(r"upstream|golden|stockfish|\bSF\b", re.I)


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, cwd=REPO, check=True, capture_output=True, text=True).stdout


def pin() -> str:
    return PIN_FILE.read_text().strip()


def upstream_files(sha: str) -> dict[str, str]:
    """basename -> full path at the pinned tree (this repo's upstream objects)."""
    out = run(["git", "ls-tree", "-r", "--name-only", sha, "--", "src/"])
    table: dict[str, str] = {}
    for path in out.splitlines():
        if not path.endswith((".cpp", ".h")):
            continue
        base = path.rsplit("/", 1)[-1]
        if base in table:
            sys.exit(f"duplicate upstream basename {base}: {table[base]} and {path}")
        table[base] = path
    return table


def zfish_citations() -> dict[str, dict[str, int]]:
    """cited basename -> {zfish file -> citation count}."""
    tracked = run(["git", "ls-files", "src"]).splitlines()
    cites: dict[str, dict[str, int]] = {}

    def add(base: str, owner: str) -> None:
        cites.setdefault(base, {})
        cites[base][owner] = cites[base].get(owner, 0) + 1

    for rel in tracked:
        if not rel.endswith(".zig"):
            continue
        for line in (REPO / rel).read_text(errors="replace").splitlines():
            for m in CPP_REF.finditer(line):
                add(m.group(1), rel)
            line_cited = set()
            for m in H_LINE_REF.finditer(line):
                add(m.group(1), rel)
                line_cited.add(m.group(1))
            if CONTEXT.search(line):
                for m in H_CTX_REF.finditer(line):
                    if m.group(1) not in line_cited:
                        add(m.group(1), rel)
    return cites


def exceptions() -> dict[str, str]:
    table: dict[str, str] = {}
    if not EXCEPTIONS.exists():
        return table
    for line in EXCEPTIONS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition("\t")
        table[name.strip()] = reason.strip()
    return table


def build_map():
    table = upstream_files(pin())
    cites = zfish_citations()
    mapped: dict[str, dict[str, int]] = {}
    phantoms: dict[str, dict[str, int]] = {}
    for base, owners in cites.items():
        if base in table:
            mapped[table[base]] = owners
        else:
            phantoms[base] = owners
    excused = exceptions()
    uncovered = sorted(p for p in table.values() if p not in mapped and p not in excused)
    return mapped, uncovered, phantoms


def declared_rules() -> list[tuple[str, list[str]]]:
    """(src-glob, [owner files]) rows of the hand-maintained map, prose stripped."""
    rules: list[tuple[str, list[str]]] = []
    for line in DECLARED.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        owners = []
        for cell in cols[1].split(","):
            cell = cell.strip()
            # Owner cells mix paths with prose annotations; keep only path-shaped
            # src/ entries (the audit is about files, not the prose).
            if not cell or "(" in cell or " " in cell:
                continue
            if cell.startswith("src/"):
                owners.append(cell)
        rules.append((cols[0], owners))
    return rules


def audit() -> int:
    mapped, _, _ = build_map()
    rules = declared_rules()
    tracked = set(run(["git", "ls-files", "src"]).splitlines())
    failures = 0

    # Rot: declared owner paths that no longer exist in the tree.
    for glob, owners in rules:
        for owner in owners:
            if owner not in tracked:
                print(f"ROT: {glob} declares owner {owner} which is not in the tree")
                failures += 1

    # Drift: derived owners the declared glob's rule does not mention. Advisory --
    # the declared map is a BLAST-RADIUS list, so extra derived owners mean the
    # radius grew; report so the router's risk model catches up.
    for path in sorted(mapped):
        rule_owners: set[str] = set()
        for glob, owners in rules:
            if fnmatch.fnmatch(path, glob):
                rule_owners = set(owners)
                break
        if not rule_owners:
            continue
        derived = set(mapped[path])
        missing = sorted(d for d in derived if d not in rule_owners)
        if missing:
            print(f"DRIFT: {path}: derived owners not in the declared rule: {', '.join(missing)}")
    return failures


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="coverage summary only")
    ap.add_argument("--audit", action="store_true", help="declared-map rot/drift report")
    ap.add_argument(
        "--baseline",
        type=int,
        default=None,
        help="fail if the uncovered count exceeds this ratchet "
        "(default: tools/upstream/upstream_map.baseline)",
    )
    args = ap.parse_args()

    if args.audit:
        failures = audit()
        if failures:
            sys.exit(1)
        # Single-source the ratchet: build.zig's `upstream-map` step and the weekly
        # CI lane both run bare `--audit`, so the number lives in one file. Lower it
        # as citations land; never raise it.
        baseline = args.baseline
        if baseline is None and BASELINE.exists():
            baseline = int(BASELINE.read_text().strip())
        if baseline is not None:
            _, uncovered, _ = build_map()
            if len(uncovered) > baseline:
                print(
                    f"RATCHET: uncovered {len(uncovered)} > baseline {baseline} "
                    f"-- new upstream surface without an owner citation or exception"
                )
                sys.exit(1)
            print(f"ratchet: uncovered {len(uncovered)} <= baseline {baseline}")
        sys.exit(0)

    mapped, uncovered, phantoms = build_map()
    total = len(mapped) + len(uncovered)

    if not args.check:
        for path in sorted(mapped):
            owners = mapped[path]
            ranked = sorted(owners, key=lambda o: -owners[o])
            cells = ",".join(f"{o}({owners[o]})" for o in ranked)
            print(f"{path}\t{cells}")
        print()

    print(f"coverage: {len(mapped)}/{total} upstream files cited from src/ (pin {pin()[:9]})")
    if uncovered:
        print(f"uncovered ({len(uncovered)}): unported surface or ported code missing its citation")
        for p in uncovered:
            print(f"  {p}")
    if phantoms:
        print(f"phantoms ({len(phantoms)}): cited names absent at the pin -- drift or typos")
        for base in sorted(phantoms):
            owners = phantoms[base]
            print(f"  {base}  cited by {', '.join(sorted(owners))}")


if __name__ == "__main__":
    main()
