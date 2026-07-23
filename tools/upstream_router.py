#!/usr/bin/env python3
"""Blast-radius router.

Classify an upstream commit (or range) by which Zig file(s) it forces us to touch and
at what risk tier, reading the manifest at tools/upstream/upstream_map.tsv. Turns
"what does this commit cost us" into a mechanical lookup instead of archaeology.

Usage:
    upstream_router.py <ref>            # single commit (e.g. 7c7fe322e) or range (base..target)
    upstream_router.py --backlog        # one line per commit over UPSTREAM_BASE..UPSTREAM_TARGET,
                                        #   sorted by risk then date, with bench targets
"""

import fnmatch
import os
import re
import subprocess
import sys

REPO = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
MAP = os.path.join(REPO, "tools/upstream/upstream_map.tsv")
RANK = {"SKIP": 0, "LOW": 1, "MED": 2, "HIGH": 3}

# A commit whose SUBJECT matches one of these is arch/platform/CI-only and is SKIP for the
# x86-64-sse41-popcnt native target, even when it touches files under a HIGH glob
# (e.g. nnue/simd.h NEON paths). Downgraded tier is shown as "SKIP*" so the commit
# stays visible for a human spot-check.
# No trailing \b: tokens like "wasm32"/"avx512icl" carry digit/word suffixes that would break it.
PLATFORM_RE = re.compile(
    r"\b(neon|loongarch|lsx|lasx|wasm|android|arm64|aarch64|armv8|macos|mac os|universal binar|"
    r"avx512|sde action|pext|prerelease|binary release|binaries|makefile|workflow|"
    r"bug report|excavator|"
    r"madv_populate|page support|large page|l3 cache)",
    re.I,
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
    m = re.search(r"Bench:\s*([0-9]+)", body, re.I)
    return m.group(1) if m else "—"


# A4: commits that change arithmetic in these files need a C++<->Zig integer-semantics review
# (unsigned promotion like `int * uint64_t`, shift signedness, `/` truncation
# direction, overflow/wrap).
FORMULA_FILES = (
    "src/search.cpp",
    "src/evaluate.cpp",
    "src/movepick.cpp",
    "src/history.h",
    "src/tt.cpp",
)


def touches_formula(files):
    return any(f in FORMULA_FILES for f in files)


# A real NNUE *architecture* change touches one of these core files (not just an
# incidental nnue source
# like network.cpp, and not a plain net bump). These are the deep, bit-exact-quantization ports.
NNUE_ARCH_FILES = (
    "src/nnue/nnue_architecture.h",
    "src/nnue/nnue_feature_transformer.h",
    "src/nnue/nnue_accumulator.h",
    "src/nnue/nnue_accumulator.cpp",
    "src/nnue/nnue_common.h",
    "src/nnue/nnz_helper.h",
)
NET_BUMP_RE = re.compile(r"^updated? main network to nn-", re.I)


def touches_nnue_arch(files):
    return any(f in NNUE_ARCH_FILES for f in files)


def base_target():
    # UPSTREAM_BASE_OVERRIDE lets upstream_sync.sh pass the live base it just computed.
    base = os.environ.get("UPSTREAM_BASE_OVERRIDE")
    if not base:
        with open(os.path.join(REPO, "tools/upstream/UPSTREAM_BASE")) as fh:
            base = fh.read().strip()
    with open(os.path.join(REPO, "tools/upstream/UPSTREAM_TARGET")) as fh:
        target = fh.read().strip()
    return base, target


def build_rows(base, target, rules):
    rows = []
    for sha in git("log", "--reverse", "--no-merges", "--format=%H", f"{base}..{target}").split():
        files = files_of(sha)
        subj = git("log", "-1", "--format=%s", sha).strip()
        risk, owners, _ = classify(files, rules)
        plat = bool(PLATFORM_RE.search(subj))
        disp = "SKIP*" if (plat and risk != "SKIP") else risk
        eff = "SKIP" if disp == "SKIP*" else risk
        bench = bench_of(sha)
        rows.append(
            {
                "disp": disp,
                "eff": eff,
                "short": git("rev-parse", "--short", sha).strip(),
                "bench": bench,
                "subj": subj,
                "owners": owners if eff != "SKIP" else set(),
                "bench_mover": bench != "—",
                "formula": eff != "SKIP" and touches_formula(files),
                "nnue_arch": eff != "SKIP" and touches_nnue_arch(files),
                "net_bump": bool(NET_BUMP_RE.match(subj)),
            }
        )
    return rows


def fmt_flags(r):
    f = []
    if r["formula"]:
        f.append("FORMULA")
    if r["nnue_arch"]:
        f.append("NNUE-ARCH")
    return ("  [" + ",".join(f) + "]") if f else ""


def main():
    rules = load_rules()
    args = sys.argv[1:]

    if args and args[0] in ("--backlog", "--worklist"):
        base, target = base_target()
        rows = build_rows(base, target, rules)
        worklist_only = args[0] == "--worklist"
        if worklist_only:
            # A7: the worklist is exactly the commits that need action -- bench-movers,
            # NNUE-arch ports,
            # and net bumps (trivial swap). Everything else is no-op / audit-only.
            shown = [
                r
                for r in rows
                if r["eff"] != "SKIP" and (r["bench_mover"] or r["nnue_arch"] or r["net_bump"])
            ]
            print(
                f"# worklist: {len(shown)} of {len(rows)} commits need action "
                f"(NNUE-arch ports + bench-movers + net swaps); the rest are no-ops/audit-only."
            )
            for r in shown:
                tag = "NNUE" if r["nnue_arch"] else ("NET" if r["net_bump"] else "bench")
                print(f"{tag:5}  {r['short']:10}  bench={r['bench']:9}  {r['subj']}{fmt_flags(r)}")
                if r["owners"] and not r["net_bump"]:
                    print(f"          -> {','.join(sorted(r['owners']))}")
            return
        from collections import Counter

        tally = Counter(r["eff"] for r in rows)
        for r in rows:
            print(
                f"{r['disp']:5}  {r['short']:10}  bench={r['bench']:9}  {r['subj']}{fmt_flags(r)}"
            )
            if r["owners"]:
                print(f"          -> {','.join(sorted(r['owners']))}")
        print(
            "\nbacklog:",
            "  ".join(f"{k}={tally.get(k, 0)}" for k in ("HIGH", "MED", "LOW", "SKIP")),
            f"  total={len(rows)}   "
            "(SKIP* = arch/platform subject; FORMULA = integer-semantics review)",
            file=sys.stderr,
        )
        return

    ref = args[0] if args else "upstream/master"
    files = files_of(ref)
    risk, owners, unmapped = classify(files, rules)
    plat = False
    if ".." not in ref:
        subj = git("log", "-1", "--format=%s", ref).strip()
        plat = bool(PLATFORM_RE.search(subj))
    print(f"risk={'SKIP* (arch/platform subject)' if (plat and risk != 'SKIP') else risk}")
    if not (plat and risk != "SKIP"):
        for o in sorted(owners):
            print(f"  zig: {o}")
        if ".." not in ref and touches_formula(files):
            print(
                "  note: FORMULA commit -> review C++/Zig integer semantics "
                "(unsigned mul, shifts, /trunc)"
            )
        if ".." not in ref and touches_nnue_arch(files):
            print("  note: NNUE-ARCH commit -> may change net format / accumulator / quantization")
    if unmapped:
        print("  unmapped:", ", ".join(unmapped))


if __name__ == "__main__":
    main()
