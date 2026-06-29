#!/usr/bin/env python3
"""Blast-radius router (REPORT-13 §5.3).

Classify an upstream commit (or range) by which Zig file(s) it forces us to touch and at what risk tier,
reading the manifest at zig_build/tools/upstream/upstream_map.tsv. Turns "what does this commit cost us" into a
mechanical lookup instead of archaeology.

Usage:
    upstream_router.py <ref>            # single commit (e.g. 7c7fe322e) or range (base..target)
    upstream_router.py --backlog        # one line per commit over UPSTREAM_BASE..UPSTREAM_TARGET,
                                        #   sorted by risk then date, with bench targets
"""
import subprocess, sys, fnmatch, os

REPO = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
MAP = os.path.join(REPO, "zig_build/tools/upstream/upstream_map.tsv")
RANK = {"SKIP": 0, "LOW": 1, "MED": 2, "HIGH": 3}

# A commit whose SUBJECT matches one of these is arch/platform/CI-only and is SKIP for the
# x86-64-sse41-popcnt native target, even when it touches files under a HIGH glob (e.g. nnue/simd.h NEON
# paths). Downgraded tier is shown as "SKIP*" so the commit stays visible for a human spot-check.
import re as _re
# No trailing \b: tokens like "wasm32"/"avx512icl" carry digit/word suffixes that would break it.
PLATFORM_RE = _re.compile(
    r"\b(neon|loongarch|lsx|lasx|wasm|android|arm64|aarch64|armv8|macos|mac os|universal binar|"
    r"avx512|sde action|pext|prerelease|binary release|binaries|makefile|workflow|bug report|excavator|"
    r"madv_populate|page support|large page|l3 cache)",
    _re.I,
)


def load_rules():
    rules = []
    with open(MAP) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            glob, owner, risk = line.split("\t")
            rules.append((glob, owner, risk.strip()))
    return rules


def git(*args):
    return subprocess.check_output(["git", "-C", REPO, *args], text=True)


def classify(files, rules):
    owners, maxrisk, unmapped = set(), "SKIP", []
    for f in files:
        hit = None
        for glob, owner, risk in rules:
            if fnmatch.fnmatch(f, glob):
                hit = (owner, risk)
                break
        if hit:
            if hit[1] != "SKIP":
                owners.add(hit[0])
            if RANK[hit[1]] > RANK[maxrisk]:
                maxrisk = hit[1]
        else:
            unmapped.append(f)
    return maxrisk, owners, unmapped


def files_of(ref):
    if ".." in ref:
        return git("diff", "--name-only", ref).split()
    return [x for x in git("show", "--name-only", "--format=", ref).split() if x]


def bench_of(sha):
    body = git("log", "-1", "--format=%b", sha)
    m = _re.search(r"Bench:\s*([0-9]+)", body, _re.I)
    return m.group(1) if m else "—"


def main():
    rules = load_rules()
    args = sys.argv[1:]
    if args and args[0] == "--backlog":
        base = open(os.path.join(REPO, "zig_build/tools/upstream/UPSTREAM_BASE")).read().strip()
        target = open(os.path.join(REPO, "zig_build/tools/upstream/UPSTREAM_TARGET")).read().strip()
        rows = []
        for sha in git("log", "--reverse", "--no-merges", "--format=%H", f"{base}..{target}").split():
            short = git("rev-parse", "--short", sha).strip()
            subj = git("log", "-1", "--format=%s", sha).strip()
            risk, owners, unmapped = classify(files_of(sha), rules)
            plat = bool(PLATFORM_RE.search(subj))
            disp = "SKIP*" if (plat and risk != "SKIP") else risk
            eff = "SKIP" if disp == "SKIP*" else risk  # tier used for the tally
            rows.append((disp, eff, short, bench_of(sha), subj, owners if eff != "SKIP" else set()))
        from collections import Counter
        tally = Counter(r[1] for r in rows)
        for disp, eff, short, bench, subj, owners in rows:
            print(f"{disp:5}  {short:10}  bench={bench:9}  {subj}")
            if owners:
                print(f"          -> {','.join(sorted(owners))}")
        print("\nbacklog:", "  ".join(f"{k}={tally.get(k,0)}" for k in ("HIGH", "MED", "LOW", "SKIP")),
              f"  total={len(rows)}   (SKIP* = arch/platform subject, skippable for sse41)", file=sys.stderr)
        return
    ref = args[0] if args else "upstream/master"
    risk, owners, unmapped = classify(files_of(ref), rules)
    plat = False
    if ".." not in ref:
        subj = git("log", "-1", "--format=%s", ref).strip()
        plat = bool(PLATFORM_RE.search(subj))
    print(f"risk={'SKIP* (arch/platform subject)' if (plat and risk != 'SKIP') else risk}")
    if not (plat and risk != "SKIP"):
        for o in sorted(owners):
            print(f"  zig: {o}")
    if unmapped:
        print("  unmapped:", ", ".join(unmapped))


if __name__ == "__main__":
    main()
