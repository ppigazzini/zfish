#!/usr/bin/env python3
"""Frozen-type live-dereference counter (REPORT-11 E2.1).

The E3 cut forward-declares the 9 frozen src/ types and drops the src/ header
includes. A *pointer/reference* to a forward-declared type is legal C++; what
breaks compilation is a DEREFERENCE that needs the COMPLETE type:

    sizeof(T)              T::method(){...} / T::x          new T / T t;
    static_cast<T*>(p)->m  obj.member (on a T-typed object)

This tool counts those, per frozen type, in the DEFAULT-compiled regions of the
bridge (legacy-#ifdef'd code is excluded -- it goes away with the oracle). It is
the E2 burndown metric: drive the achievable count toward 0 (member-access shims
-> native offsets, sizeof(T) -> graph_layout constants, legacy branches comptime-
confined) so the E3 cut is forward-declaration only. The irreducible remainder is
the native-shim method bodies (e.g. Position::do_move, Engine::get_options) that
are load-bearing via the src/ header inlines -- those move/forward-decl AT the cut.

Usage:  python3 frozen_refs.py [path-to-uci_bridge.cpp] [-v]
        -v lists every hit with its line number + kind (for targeting).
"""
import re
import sys

TYPES = [
    "Stockfish::Engine", "UCIEngine", "ThreadPool", "Position", "Thread",
    "Search::Worker", "Search::SearchManager", "Search::SharedState",
    "StateInfo", "OptionsMap", "NumaReplicationContext", "NumaConfig",
]

path = next((a for a in sys.argv[1:] if not a.startswith("-")), "zig_compat/uci_bridge.cpp")
verbose = "-v" in sys.argv
lines = open(path).read().split("\n")


def default_code_lines(lines):
    """Yield (lineno, code-without-comment) for DEFAULT-compiled lines only."""
    state = []
    for i, ln in enumerate(lines):
        st = ln.strip()
        if st.startswith("#ifdef ZFISH_LEGACY_CPP_TARGET"):
            state.append("L"); continue
        if st.startswith("#ifndef ZFISH_LEGACY_CPP_TARGET"):
            state.append("D"); continue
        if st.startswith("#if"):
            state.append("O"); continue
        if st.startswith("#else"):
            if state:
                state[-1] = {"L": "D", "D": "L"}.get(state[-1], state[-1])
            continue
        if st.startswith("#endif"):
            if state:
                state.pop()
            continue
        if "L" in state and "D" not in state:
            continue  # legacy-only -> excluded
        yield i + 1, ln.split("//")[0]


def patterns(t):
    short = t.split("::")[-1]
    te = re.escape(t)
    se = re.escape(short)
    return [
        (re.compile(r"\bsizeof\s*\(\s*(?:Stockfish::)?" + se + r"\b"), "sizeof"),
        (re.compile(r"\b" + se + r"::"), "scope"),  # T::method def or call
        (re.compile(r"static_cast<\s*(?:const\s+)?(?:Stockfish::)?" + se + r"\s*[*&]\s*>\s*\([^;]*\)\s*[-.]"), "cast-deref"),
        (re.compile(r"\bnew\s+(?:Stockfish::)?" + se + r"\b"), "new"),
    ]


dl = list(default_code_lines(lines))
total = 0
by_type = {}
for t in TYPES:
    pats = patterns(t)
    hits = []
    for ln, code in dl:
        for rx, kind in pats:
            if rx.search(code):
                hits.append((ln, kind))
                break
    if hits:
        by_type[t] = hits
        total += len(hits)

for t in sorted(by_type, key=lambda k: -len(by_type[k])):
    kinds = {}
    for _, k in by_type[t]:
        kinds[k] = kinds.get(k, 0) + 1
    kindstr = " ".join(f"{k}={v}" for k, v in sorted(kinds.items()))
    print(f"{t:28} {len(by_type[t]):3}   ({kindstr})")
    if verbose:
        for ln, k in by_type[t]:
            print(f"      {ln} [{k}]")
print(f"{'TOTAL live frozen-type derefs (default)':28} {total:3}")
