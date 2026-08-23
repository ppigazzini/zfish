#!/usr/bin/env python3
"""Replay a fixed game at a fixed depth -- the workload a long clock actually reaches.

WHY THIS EXISTS. Every speed axis in tools/ drives `bench`: perf_budget.sh, perf_counters,
perf_callgrind.sh and nps_ab.sh all measure a COLD search of a fixed position list at depth
8 or 13, against a transposition table the previous position barely warmed. A move at
fishtest's 10+0.1 is the opposite workload in three ways at once:

  * it runs at ply 40 of ONE game, on a table every earlier move of that game has written
    end to end, and on the history, pawn and correction banks those moves populated;
  * it reaches depth 20 to 25, not 8 or 13;
  * and the tree it searches is therefore far smaller per ply, because the move ordering it
    inherits is already good.

A per-node ratio measured in the first regime does not transfer to the second, so a change
that pays only once the table is full is invisible to every gate this repo had.

DETERMINISM, and why the node total is the fidelity check. The move list is fixed input,
every search is `go depth D`, and one thread makes the node count a function of the position
and the table alone. Two revisions that search the same tree MUST report the same node total
at every ply. That equality is a WIDER net than the bench anchor, which only ever visits its
own thirteen positions from a cold table -- so a divergence off those positions, the class
docs/10-tooling-ci.md records the anchor cannot see, reddens this. A run whose totals differ
is VOID, not slow.

Run from resources/, which is the cwd holding the net (AGENTS.md).

    # record a move list once -- deterministic given depth, hash and binary
    python3 ../tools/ltc_replay.py record --bin ../zig-out/bin/stockfish \
        --depth 14 --plies 60 > /tmp/game.moves

    # replay it: per-ply TSV on stdout, one summary line last
    python3 ../tools/ltc_replay.py replay --bin ../zig-out/bin/stockfish \
        --depth 20 --moves /tmp/game.moves --hash 16

    # the same replay with the accumulated state thrown away before every move --
    # the direct measurement of what a warm table and a warm history bank are worth
    python3 ../tools/ltc_replay.py replay ... --cold

    # with hardware counters, through tools/perf_counters --wrap
    python3 ../tools/ltc_replay.py replay ... --counters ./perf_counters
"""

import argparse
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


class Engine:
    """A UCI process that stays alive until `quit`.

    A shell pipe closes stdin after the last command, the UCI loop reads EOF and quits
    MID-SEARCH -- returning a depth-1 move and exit code 0, with nothing in the output
    saying the search was cut short. That is the trap the `upstream-walk` note records and
    the one tools/liveness.sh drives a FIFO to avoid; this class exists so a replay cannot
    fall into it.
    """

    def __init__(self, argv, options):
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        # Popen types both pipes as optional because they are absent unless asked for.
        # They were asked for, so bind them once rather than asserting at every use.
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout
        self.send("uci")
        self.until(r"^uciok\b")
        for key, value in options.items():
            self.send(f"setoption name {key} value {value}")
        self.ready()

    def send(self, line):
        self.stdin.write(line + "\n")
        self.stdin.flush()

    def until(self, pattern):
        rx, lines = re.compile(pattern), []
        while True:
            line = self.stdout.readline()
            if not line:
                raise SystemExit("ltc_replay: the engine died mid-command")
            lines.append(line.rstrip("\n"))
            if rx.search(line):
                return lines

    def ready(self):
        self.send("isready")
        self.until(r"^readyok\b")

    def go(self, command):
        """Return (lines, wall_us). The wall clock spans the whole `go`."""
        start = time.perf_counter_ns()
        self.send(command)
        lines = self.until(r"^bestmove\b")
        return lines, (time.perf_counter_ns() - start) // 1000

    def quit(self):
        try:
            self.send("quit")
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.kill()
        return self.proc.returncode


def field(line, name, cast=int):
    match = re.search(rf"\b{name} (\S+)", line)
    return cast(match.group(1)) if match else None


def summarise(lines):
    """The last `info` line carrying a node count, plus the bestmove."""
    infos = [x for x in lines if x.startswith("info ") and " nodes " in x]
    best = next((x.split()[1] for x in lines if x.startswith("bestmove")), None)
    return (infos[-1] if infos else ""), best


def open_engine(args, counters_out=None):
    argv = [str(args.bin)]
    if counters_out:
        argv = [
            str(args.counters),
            "--wrap",
            "-o",
            str(counters_out),
            "--core",
            str(args.core),
            "--",
            *argv,
        ]
    if args.wrap:
        # A launcher prefix -- valgrind, taskset, a sanitizer runner. It goes OUTSIDE the
        # counter harness, so the harness still measures the child it spawned rather than
        # the launcher: a profile of the launcher is the mistake this ordering forecloses.
        argv = shlex.split(args.wrap) + argv
    options = {"Threads": args.threads, "Hash": args.hash}
    if args.multipv != 1:
        options["MultiPV"] = args.multipv
    for pair in args.setoption:
        name, _, value = pair.partition("=")
        if not _:
            raise SystemExit(f"ltc_replay: --setoption wants NAME=VALUE, got '{pair}'")
        options[name] = value
    return Engine(argv, options)


def position_command(start, moves):
    head = "position startpos" if start == "startpos" else f"position fen {start}"
    return head + (" moves " + " ".join(moves) if moves else "")


def cmd_record(args):
    engine = open_engine(args)
    engine.send("ucinewgame")
    engine.ready()
    moves = []
    for _ in range(args.plies):
        engine.send(position_command(args.start, moves))
        lines, _ = engine.go(f"go depth {args.depth}")
        _, best = summarise(lines)
        if best in (None, "(none)", "0000"):
            break
        moves.append(best)
    engine.quit()
    print(" ".join(moves))
    return 0


def cmd_replay(args):
    moves = Path(args.moves).read_text().split()
    if args.plies:
        moves = moves[: args.plies]

    counters_out = Path(args.counters_out) if args.counters else None
    engine = open_engine(args, counters_out)
    engine.send("ucinewgame")
    engine.ready()

    rows = []
    played = []
    for ply, move in enumerate(moves):
        if args.cold:
            engine.send("ucinewgame")
            engine.ready()
        engine.send(position_command(args.start, played))
        lines, wall = engine.go(f"go depth {args.depth}")
        info, best = summarise(lines)
        if not info:
            raise SystemExit(f"ltc_replay: no info line at ply {ply}")
        rows.append(
            dict(
                ply=ply,
                depth=field(info, "depth") or 0,
                seldepth=field(info, "seldepth") or 0,
                nodes=field(info, "nodes") or 0,
                ms=field(info, "time") or 0,
                hashfull=field(info, "hashfull") or 0,
                wall_us=wall,
                best=best or "-",
            )
        )
        played.append(move)

    code = engine.quit()
    if code not in (0, None):
        raise SystemExit(f"ltc_replay: the engine exited {code}")

    print("ply\tdepth\tseldepth\tnodes\tms\twall_us\thashfull\tbest")
    for r in rows:
        print(
            f"{r['ply']}\t{r['depth']}\t{r['seldepth']}\t{r['nodes']}\t"
            f"{r['ms']}\t{r['wall_us']}\t{r['hashfull']}\t{r['best']}"
        )

    nodes = sum(int(r["nodes"]) for r in rows)
    ms = sum(int(r["ms"]) for r in rows)
    wall = sum(int(r["wall_us"]) for r in rows)
    # The engine's own clock starts inside `go`, so `ms` excludes whatever the `position`
    # command and the search setup cost, where `wall_us` includes both. Their difference IS
    # the per-`go` fixed cost -- the term the move-latency work is aimed at, and the one
    # that decays as the move lengthens.
    print(
        f"replay: plies={len(rows)} nodes={nodes} ms={ms} wall_us={wall} "
        f"fixed_us={wall - ms * 1000} "
        f"nps={int(nodes * 1000 / ms) if ms else 0} "
        f"maxdepth={max(r['depth'] for r in rows)} "
        f"hashfull_last={rows[-1]['hashfull']}"
    )

    if counters_out and counters_out.exists():
        print(counters_out.read_text().strip())
    return 0


def cmd_startup(args):
    """Open the engine, wait for readyok, quit -- and nothing else.

    THE STARTUP FLOOR. A counter total taken over a replay includes everything the process
    did before the first node: mapping the binary, reading and validating the .nnue, building
    the transposition table. Two revisions do not pay the same price for that, so a per-node
    figure computed from the raw total attributes a startup difference to the search. This
    mode measures the floor on its own so the A/B can subtract each binary's own.

    It is the same session the replay opens -- same options, same Hash -- with the move loop
    removed, so what it measures is exactly what the replay carries in addition to its nodes.
    """
    counters_out = Path(args.counters_out) if args.counters else None
    engine = open_engine(args, counters_out)
    engine.send("ucinewgame")
    engine.ready()
    code = engine.quit()
    if code not in (0, None):
        raise SystemExit(f"ltc_replay: the engine exited {code}")
    print("startup: plies=0 nodes=0")
    if counters_out and counters_out.exists():
        print(counters_out.read_text().strip())
    return 0


def cmd_clock(args):
    """Play one side of a fixed game on a NODE clock, and report what the time manager did.

    THE POINT. Every question of the form "does a faster engine convert its speed into Elo
    at this time control" runs into one wall: a real clock is wall time, wall time is not
    reproducible here (docs/08-idiomatic-zig.md prices the floor), and the answer is then an
    SPRT and 40,000 games. `nodestime` removes the wall clock entirely -- with it set the
    engine's own elapsed() returns NODES and the budget is a node bank it keeps itself, so a
    whole game becomes a deterministic function of the move list.

    A faster engine is then simply a LARGER --npmsec: at 1000 nodes per millisecond a 1 ms
    budget buys 1,000 nodes, at 1100 it buys 1,100. Two runs of this mode at --npmsec 1000
    and 1100 are the same engine playing the same game with a 10% speed advantage and the
    REAL time manager in the loop, and the difference in the depth it reaches is how much of
    that 10% the time manager let it keep.
    """
    moves = Path(args.moves).read_text().split()
    if args.plies:
        moves = moves[: args.plies]

    engine = open_engine(args)
    engine.send(f"setoption name nodestime value {args.npmsec}")
    # ucinewgame is what makes the first `go` of the game seed the bank from wtime rather
    # than inherit the previous game's remainder.
    engine.send("ucinewgame")
    engine.ready()

    # The engine keeps the authoritative bank; this mirrors it so the run can report what is
    # left without reading the engine's private state. Both use the same arithmetic:
    # timeman.zig subtracts (nodes searched - increment) and floors at zero.
    bank = args.npmsec * args.base_ms
    inc_nodes = args.npmsec * args.inc_ms

    rows = []
    played = []
    flagged = -1
    for ply, move in enumerate(moves):
        # Only OUR side gets a `go`. There is one time manager per search manager and one
        # node bank inside it, so searching both colours out of one process would spend one
        # bank for two players.
        if ply % 2 != (0 if args.side == "white" else 1):
            played.append(move)
            continue
        engine.send(position_command(args.start, played))
        lines, wall = engine.go(
            f"go wtime {args.base_ms} btime {args.base_ms} winc {args.inc_ms} binc {args.inc_ms}"
        )
        info, best = summarise(lines)
        if not info:
            raise SystemExit(f"ltc_replay: no info line at ply {ply}")
        nodes = field(info, "nodes") or 0
        before = bank
        bank = max(0, bank - (nodes - inc_nodes))
        if bank == 0 and flagged < 0:
            flagged = ply
        rows.append(
            dict(
                ply=ply,
                depth=field(info, "depth") or 0,
                seldepth=field(info, "seldepth") or 0,
                nodes=nodes,
                budget_ms=before // args.npmsec,
                bank=bank,
                wall_us=wall,
                best=best or "-",
            )
        )
        played.append(move)

    engine.quit()

    print("ply\tdepth\tseldepth\tnodes\tbudget_ms\tbank\tbest")
    for r in rows:
        print(
            f"{r['ply']}\t{r['depth']}\t{r['seldepth']}\t{r['nodes']}\t"
            f"{r['budget_ms']}\t{r['bank']}\t{r['best']}"
        )

    nodes = sum(int(r["nodes"]) for r in rows)
    depths = [int(r["depth"]) for r in rows]
    granted = args.npmsec * args.base_ms + inc_nodes * len(rows)
    spent = granted - bank
    print(
        f"clock: moves={len(rows)} npmsec={args.npmsec} "
        f"tc={args.base_ms}+{args.inc_ms}ms nodes={nodes} "
        f"mean_depth={sum(depths) / max(1, len(depths)):.3f} "
        f"min_depth={min(depths)} max_depth={max(depths)} "
        f"bank_left={bank} granted={granted} "
        f"spent_frac={spent / max(1, granted):.4f} flagged_at={flagged}"
    )
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("mode", choices=("record", "replay", "startup", "clock"))
    parser.add_argument(
        "--bin",
        default="./stockfish",
        help="the engine binary -- the BINARY is named stockfish, not zfish (default: ./stockfish)",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=20,
        help="fixed search depth per move -- 20 to 25 is what a 10+0.1 move "
        "reaches on a modern core (default: 20)",
    )
    parser.add_argument("--hash", type=int, default=16, help="Hash in MB (default: 16)")
    parser.add_argument(
        "--threads",
        type=int,
        default=1,
        help="Threads (default: 1 -- more than one is not deterministic)",
    )
    parser.add_argument("--multipv", type=int, default=1)
    parser.add_argument(
        "--plies", type=int, default=60, help="plies to record, or a prefix of the replay"
    )
    parser.add_argument("--start", default="startpos", help="'startpos' or a FEN")
    parser.add_argument("--moves", help="move-list file (replay, clock)")
    parser.add_argument(
        "--cold",
        action="store_true",
        help="send ucinewgame before every move: throws the table and the history "
        "bank away, so the replay measures a COLD search at a long-clock depth",
    )
    parser.add_argument(
        "--setoption",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="an extra UCI option, repeatable; e.g. --setoption 'Move Overhead=0'",
    )
    parser.add_argument(
        "--npmsec",
        type=int,
        default=1000,
        help="clock mode: nodes per millisecond -- this IS the engine's "
        "simulated speed (default: 1000)",
    )
    parser.add_argument(
        "--base-ms",
        type=int,
        default=10000,
        help="clock mode: base time in ms (default: 10000, which with "
        "--inc-ms 100 is fishtest STC 10+0.1)",
    )
    parser.add_argument(
        "--inc-ms", type=int, default=100, help="clock mode: increment in ms (default: 100)"
    )
    parser.add_argument(
        "--side",
        choices=("white", "black"),
        default="white",
        help="clock mode: which side the engine plays",
    )
    parser.add_argument(
        "--wrap",
        default="",
        help="launcher prefix for the engine, e.g. "
        "'valgrind --tool=callgrind --callgrind-out-file=cg.out'",
    )
    parser.add_argument("--counters", help="path to the built tools/perf_counters")
    parser.add_argument(
        "--core",
        type=int,
        default=0,
        help="core the counter harness pins the ENGINE to. Pin this driver to a "
        "different one (taskset) or the two share a core and the engine loses half "
        "its throughput -- which voids the cycle and wall columns, though not the "
        "instruction column this axis reads (default: 0)",
    )
    parser.add_argument("--counters-out", default="/tmp/ltc_replay.counters")
    args = parser.parse_args()

    if args.mode in ("replay", "clock") and not args.moves:
        parser.error(f"{args.mode} needs --moves")
    if args.mode == "clock" and not 1 <= args.npmsec <= 10000:
        parser.error("--npmsec must be in 1..10000 (the UCI option's range)")
    if args.threads != 1:
        print("ltc_replay: WARNING -- Threads != 1 is not deterministic", file=sys.stderr)

    return {
        "record": cmd_record,
        "replay": cmd_replay,
        "startup": cmd_startup,
        "clock": cmd_clock,
    }[args.mode](args)


if __name__ == "__main__":
    sys.exit(main())
