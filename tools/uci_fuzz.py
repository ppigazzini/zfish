#!/usr/bin/env python3
"""Bounded, seeded fuzz of the UCI front end against the safety-checked engine.

The shell's parser and session layer face arbitrary bytes on stdin; the golden
transcripts only exercise the well-formed subset, and the coverage-guided
`zig build fuzz` targets stop at the board layer (FEN parse, movegen,
make/unmake) -- nothing feeds the COMMAND LOOP hostile input. This harness
drives a ReleaseSafe (or Debug, which adds the 0xAA alloc poison) build with
seeded pseudo-random command streams -- well-formed commands, boundary values,
truncated and mangled lines, binary junk -- and requires every stream to end
with a clean exit and no safety-check panic. The seed prints first, so any
failure reproduces with one flag.

The generator is deliberately weighted toward ALMOST-valid input: a parser
dies on the input that looks right until one token, not on pure noise.

Two commands stay out of the streams by design: `export_net` writes a net file
into the working directory, and `speedtest` runs for minutes. Ported from the
sibling port's tools/uci_fuzz.py; the go generator differs because this shell
searches asynchronously -- `go infinite` is includable here, since the verbatim
closing `quit` stops a running search on its way out (uci.zig routes EOF and
quit through the same stop-and-return path).

Usage (from resources/, where the net lives):
  ../tools/uci_fuzz.py --seconds N [--seed S] [--binary ../zig-out/bin/stockfish]
"""

from __future__ import annotations

import argparse
import random
import subprocess
import sys
import time

FENS = [
    "startpos",
    "fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "fen 8/2k5/8/8/3N4/8/2P5/2K5 b - - 0 1",
    "fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10",
    "fen 8/8/8/8/8/8/8/8 w - - 0 1",
    "fen invalid/board/here w KQkq - 0 1",
]
OPTIONS = ["Hash", "Threads", "MultiPV", "SyzygyPath", "Ponder", "Move Overhead",
           "NoSuchOption", ""]
MOVES = ["e2e4", "e7e5", "g1f3", "e1g1", "e7e8q", "a2a1n", "0000", "zzzz", "e2e9"]


def mangle(rng: random.Random, line: str) -> str:
    roll = rng.random()
    if roll < 0.70:
        return line
    if roll < 0.80:
        return line[: rng.randrange(len(line) + 1)]
    if roll < 0.90:
        pos = rng.randrange(len(line) + 1)
        return line[:pos] + rng.choice(["\t", "  ", "\x00", "\xff", "é"]) + line[pos:]
    return "".join(chr(rng.randrange(1, 256)) for _ in range(rng.randrange(1, 80)))


def stream(rng: random.Random) -> str:
    # (text, fuzzable) pairs. Every go line stays verbatim -- mangling one can
    # drop its bound, and while the closing quit would still stop it, a mangled
    # bound turns run time from seconds into the timeout. The final `quit` is
    # verbatim so every stream terminates the engine by construction.
    lines: list[tuple[str, bool]] = [("uci", True), ("isready", True)]
    for _ in range(rng.randrange(3, 25)):
        kind = rng.random()
        if kind < 0.25:
            moves = " ".join(rng.choices(MOVES, k=rng.randrange(0, 6)))
            lines.append((f"position {rng.choice(FENS)}"
                          + (f" moves {moves}" if moves else ""), True))
        elif kind < 0.45:
            lines.append((f"setoption name {rng.choice(OPTIONS)} value "
                          + rng.choice(["1", "0", "-1", "99999999", "true", "x" * 300, ""]),
                          True))
        elif kind < 0.70:
            # The shell searches asynchronously, so `go infinite` joins the
            # bounded forms: the paired `stop` releases it, and even a stream
            # whose stop is lost still terminates through the closing quit.
            lines.append((rng.choice([
                f"go depth {rng.randrange(1, 6)}",
                f"go nodes {rng.choice([1, 1000, 10**6])}",
                f"go movetime {rng.randrange(1, 30)}",
                f"go perft {rng.randrange(1, 4)}",
                "go infinite",
            ]), False))
            lines.append(("stop", False))
        elif kind < 0.85:
            lines.append((rng.choice(["ucinewgame", "isready", "stop", "ponderhit", "d",
                                      "bench 1 1 2", "eval", "flip", "compiler", "help"]),
                          True))
        else:
            # Mangle position/setoption commands only; go lines stay whole (see
            # the note on the verbatim go forms above).
            lines.append((mangle(rng, rng.choice(["position startpos",
                                                  "setoption name Hash value 1"])), True))
    lines.append(("quit", False))
    return "\n".join(mangle(rng, l) if fuzz else l for l, fuzz in lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--seed", type=int, default=int(time.time()))
    ap.add_argument("--binary", default="../zig-out/bin/stockfish")
    args = ap.parse_args()

    print(f"seed {args.seed}  (reproduce: uci_fuzz.py --seed {args.seed})", flush=True)
    rng = random.Random(args.seed)
    deadline = time.monotonic() + args.seconds
    runs = 0

    while time.monotonic() < deadline:
        payload = stream(rng)
        try:
            proc = subprocess.run([args.binary], input=payload.encode("utf-8", "surrogateescape"),
                                  capture_output=True, timeout=120)
        except subprocess.TimeoutExpired:
            # Every stream ends with a verbatim `quit`, so a timeout is a real
            # hang -- report it like any other failure.
            sys.stderr.write(f"FUZZ HANG at run {runs} (seed {args.seed})\n"
                             "---- input ----\n" + payload)
            sys.exit(1)
        out = proc.stdout.decode(errors="replace")
        err = proc.stderr.decode(errors="replace")
        # Two clean outcomes: exit 0, or the documented CRITICAL ERROR contract --
        # an unusable position terminates the process with exit(1) after
        # announcing itself (uci_critical.zig, upstream uci.cpp:684). Anything
        # else -- a Zig safety panic aborts with a signal, so its returncode is
        # negative here -- is a finding, as is any panic text on stderr.
        ok_exit = proc.returncode == 0 or (proc.returncode == 1 and "CRITICAL ERROR" in out)
        bad = not ok_exit or "panic" in err
        if bad:
            sys.stderr.write(f"FUZZ FAILURE at run {runs} (seed {args.seed}, "
                             f"exit {proc.returncode})\n")
            sys.stderr.write("---- input ----\n" + payload + "\n---- stderr ----\n" + err)
            sys.exit(1)
        runs += 1

    print(f"clean: {runs} streams, seed {args.seed}")


if __name__ == "__main__":
    main()
