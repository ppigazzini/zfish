#!/usr/bin/env python3
"""Diff zfish against a pristine upstream build node-for-node, on positions nobody chose.

WHY A RANDOM WALK
-----------------
The bench signature is one number over a FIXED position list. A port can be nudged toward
that number without becoming faithful -- tune a constant until the total lands, or
special-case whatever the bench happens to exercise -- and the number then says nothing
about the search. `upstream_nodes.sh` narrows that hole but does not close it: it walks a
FEN suite someone hands it, so positions no suite covers stay unprobed.

This reaches positions by playing random legal moves from the start, so they appear in no
bench list, no golden, and no test, then drives BOTH engines over them with identical
commands and compares node counts PER DEPTH. Matching upstream on positions nobody tuned
against is evidence of a faithful search; matching only on the bench set is evidence of
the opposite.

WHAT IT DOES NOT COVER. One thread, one hash size, no tablebases, and only the search --
a divergence in time management, SMP voting, or the Syzygy path is invisible here. It also
proves nothing about positions the walk did not reach; raise --positions rather than
reading a clean run as a proof over all of chess.

Usage:
    tools/upstream_walk.py [--positions N] [--depth D] [--seed S] [--plies P] [--sha SHA]
"""

import argparse
import random
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "tools"
OUR_BIN = REPO / "zig-out" / "bin" / "stockfish"

# Run zfish from resources/, never from the repo root: the net is an external runtime input
# and lives there. Started where it cannot find one, the engine dies on a null net rather
# than falling back -- which reads as a catastrophic search bug rather than a missing file.
OUR_CWD = REPO / "resources"

START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

NET_RE = re.compile(r"NNUE evaluation using (\S+\.nnue)")
DIVIDE_RE = re.compile(r"^([a-h][1-8][a-h][1-8][qrbn]?)\s*:\s*\d+")
DEPTH_RE = re.compile(r"^info depth (\d+)\b")
NODES_RE = re.compile(r"\bnodes (\d+)")


class Engine:
    """Drive one UCI engine over a pipe.

    `go` is ASYNCHRONOUS on both engines: it returns to the input loop and searches on
    another thread. Sending the next command -- or closing stdin -- before `bestmove`
    arrives aborts the search and yields a depth-1 stub that reads as a catastrophic
    divergence. Always read to `bestmove`, and never close stdin to end a search.
    """

    def __init__(self, binary: Path, cwd: Path) -> None:
        self.name = binary.name
        self.p = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            cwd=str(cwd),
        )
        # Popen types both pipes Optional; both were requested above. Hold them narrowed
        # so every method below sees a concrete handle.
        assert self.p.stdin is not None and self.p.stdout is not None
        self.stdin = self.p.stdin
        self.stdout = self.p.stdout
        self.net: str | None = None
        self._send("uci")
        self._read_until("uciok")

    def _send(self, s: str) -> None:
        self.stdin.write(s + "\n")
        self.stdin.flush()

    def _read_until(self, needle: str) -> list[str]:
        lines: list[str] = []
        while True:
            line = self.stdout.readline()
            if not line:  # the engine died; the caller reports the truncated result
                return lines
            lines.append(line)
            if self.net is None and (m := NET_RE.search(line)):
                self.net = m.group(1)
            if needle in line:
                return lines

    def setup(self, hash_mb: int = 16) -> None:
        self._send(f"setoption name Hash value {hash_mb}")
        self._send("setoption name Threads value 1")
        self.isolate()

    def isolate(self) -> None:
        """Drop the TT and the history block between positions.

        Without this the two engines are compared from different carried-over states and
        report divergences that vanish the moment either position is run alone.
        """
        self._send("ucinewgame")
        self._send("isready")
        self._read_until("readyok")

    def probe_net(self) -> None:
        """Force the net to load and report itself, so `net` is populated before comparing.

        Both engines load the net LAZILY and print `NNUE evaluation using <file>` at that
        moment -- not during the `uci` handshake and not on `isready`. Reading the field
        before something has actually used the evaluation always sees None, which silently
        turns the mismatch check below into a no-op.
        """
        self.legal_moves(START)

    def legal_moves(self, fen: str) -> list[str]:
        """Read the legal move list off `go perft 1`, which both engines print as divide."""
        self._send(f"position fen {fen}")
        self._send("go perft 1")
        return [
            m.group(1)
            for line in self._read_until("Nodes searched")
            if (m := DIVIDE_RE.match(line.strip()))
        ]

    def fen_after(self, moves: list[str]) -> str | None:
        self._send("position startpos" + (" moves " + " ".join(moves) if moves else ""))
        self._send("d")
        for line in self._read_until("Key:"):
            if line.startswith("Fen:"):
                return line.split("Fen:", 1)[1].strip()
        return None

    def nodes_by_depth(self, fen: str, depth: int) -> dict[int, int]:
        """Return {depth: nodes}, so a divergence localizes to one ID iteration."""
        self.isolate()
        self._send(f"position fen {fen}")
        self._send(f"go depth {depth}")
        out: dict[int, int] = {}
        for line in self._read_until("bestmove"):
            d, n = DEPTH_RE.search(line), NODES_RE.search(line)
            if d and n:
                out[int(d.group(1))] = int(n.group(1))
        return out

    def quit(self) -> None:
        try:
            self._send("quit")
            self.p.wait(timeout=10)
        except OSError, ValueError, subprocess.TimeoutExpired:
            self.p.kill()


def resolve_oracle(sha: str | None) -> tuple[Path, Path]:
    """Build (or reuse) the pristine oracle and return (binary, cwd).

    Go through upstream_oracle.sh rather than reaching for a path: it defaults the compiler
    to tools/zigcxx, and a gcc-built oracle measures gcc, not upstream.
    """
    cmd = [str(TOOLS / "upstream_oracle.sh")]
    if sha:
        cmd.append(sha)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.exit("upstream-walk: oracle build failed")
    binary = Path(proc.stdout.strip().splitlines()[-1])
    if not binary.exists():
        sys.exit(f"upstream-walk: oracle script named {binary}, which does not exist")
    return binary, binary.parent


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--positions", type=int, default=20)
    ap.add_argument("--depth", type=int, default=10)
    ap.add_argument("--seed", type=int, default=20260729)
    ap.add_argument("--plies", type=int, default=12)
    ap.add_argument("--sha", default=None, help="upstream sha to build the oracle at")
    args = ap.parse_args()

    if not OUR_BIN.exists():
        return int(bool(sys.stderr.write(f"no zfish binary at {OUR_BIN} -- run `zig build`\n")))
    oracle_bin, oracle_cwd = resolve_oracle(args.sha)

    ours = Engine(OUR_BIN, OUR_CWD)
    up = Engine(oracle_bin, oracle_cwd)
    ours.setup()
    up.setup()
    ours.probe_net()
    up.probe_net()

    # Refuse to compare two engines evaluating with DIFFERENT nets. Node counts are then
    # incomparable and every position reads as a divergence, which looks exactly like a
    # search bug. upstream_nodes.sh warns about this in prose; check it instead.
    if ours.net and up.net and ours.net != up.net:
        ours.quit()
        up.quit()
        return int(
            bool(
                sys.stderr.write(
                    f"upstream-walk: net mismatch -- zfish loaded {ours.net}, oracle "
                    f"loaded {up.net}. Point EvalFile at the oracle's net, or pick a sha "
                    f"that shares ours; node counts across different nets mean nothing.\n"
                )
            )
        )

    print(
        f"walk: seed {args.seed}, {args.positions} positions, "
        f"{args.plies} plies, depth {args.depth}"
    )
    print(f"      net {ours.net or '?'} | oracle {oracle_bin}")

    # Generate the sample with the ORACLE, so nothing zfish does can bias which positions
    # are chosen. A position the oracle reaches and zfish cannot is itself the finding.
    rng = random.Random(args.seed)
    fens: list[str] = []
    while len(fens) < args.positions:
        moves: list[str] = []
        for _ in range(args.plies):
            legal = up.legal_moves(up.fen_after(moves) or START)
            if not legal:
                break
            moves.append(rng.choice(legal))
        fen = up.fen_after(moves)
        if fen and up.legal_moves(fen):
            fens.append(fen)

    exact = 0
    diverged: list[tuple[str, int | None, int | None, int | None]] = []
    for fen in fens:
        a = ours.nodes_by_depth(fen, args.depth)
        b = up.nodes_by_depth(fen, args.depth)
        # Compare the depth SETS, not their intersection. Intersecting lets a run that
        # stopped early match on its short prefix and print EXACT while the summary line --
        # the number anyone quotes -- still claims N/N identical.
        shared = sorted(set(a) & set(b))
        bad = [d for d in shared if a[d] != b[d]]
        if a.keys() != b.keys():
            bad = bad or [min(set(a) ^ set(b))]
        if not bad and shared and args.depth in a:
            exact += 1
            print(f"  EXACT   d{args.depth} {a[args.depth]:>10}  {fen[:44]}")
        else:
            d0 = bad[0] if bad else None
            diverged.append((fen, d0, a.get(d0), b.get(d0)))
            print(f"  DIFF    depth {d0}: ours={a.get(d0)} up={b.get(d0)}  {fen}")

    ours.quit()
    up.quit()

    print(f"\n  {exact} / {len(fens)} random positions node-for-node identical to upstream")
    if diverged:
        shallow = min((d for _, d, _, _ in diverged if d is not None), default=None)
        if shallow is not None:
            print(f"  shallowest divergence: depth {shallow} -- fix that first, it is the")
            print("  simplest reproducer; re-run with --positions 1 --seed on that FEN.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
