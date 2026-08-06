#!/usr/bin/env bash
# upstream-transcript.
#
# Diff the WHOLE UCI transcript of the Zig build against the PRISTINE upstream oracle at
# the pinned target sha, over a matrix of command scripts. The bench signature
# (upstream_parity.sh) proves the two search the same tree; it says nothing about what the
# two PRINT. Every divergence found on the option/info surface so far -- the NumaPolicy
# parser, "Available processors" reading the affinity mask instead of the config -- was
# invisible to every gate in the tree and was found by hand, twice, after being missed by
# hand-written greps that only looked at the lines someone already suspected. Diff the
# whole transcript instead, so the next one is found by a gate.
#
# LOCAL-ONLY, like the other oracle glue: it needs the upstream worktree build, which CI
# does not have. Run it when touching the UCI, option, NUMA or info surface.
#
# Usage:  upstream_transcript.sh [<our-bin>] [<sha>]
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUR_BIN="${1:-$REPO/zig-out/bin/stockfish}"
SHA="${2:-$(cat "$REPO/tools/upstream/UPSTREAM_TARGET")}"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"

ORACLE_BIN="$("$REPO/tools/upstream_oracle.sh" "$SHA")" || {
    echo "upstream-transcript: oracle build failed" >&2; exit 2; }

# The oracle's build is checked above; OUR side was taken on trust. Name a missing binary
# here rather than letting every case run it and read the result as a transcript.
[ -x "$OUR_BIN" ] || {
    echo "upstream-transcript: no executable at $OUR_BIN -- run \`zig build\` first" >&2; exit 2; }

# Each engine runs from its own directory so each finds its own net copy; the two nets are
# byte-identical at the pin, so search output is comparable and is compared.
OUR_DIR="$REPO/resources"
THEIR_DIR="$ORACLE_DIR/src"

# Strip only what CANNOT match between two builds of different compilers: the version
# banner, and the wall-clock-derived fields. Everything else is compared byte for byte.
normalise() {
    sed -E -e '/^Stockfish dev-/d' \
           -e 's/^id name Stockfish dev-.*/id name Stockfish dev-V/' \
           -e '/^info string Available threads/d' \
           -e 's/ time [0-9]+/ time T/g' \
           -e 's/ nps [0-9]+/ nps N/g' \
           -e 's/ hashfull [0-9]+/ hashfull H/g' \
           -e 's/^(Total time \(ms\) *: ).*/\1T/' \
           -e 's/^(Nodes\/second *: ).*/\1N/'
}

# Declare the divergences that are KNOWN, so they are reported rather than silently tolerated
# and so a NEW one cannot hide behind them. The entries and the argument for each live in
# tools/transcript_known.txt; this reads them and ENFORCES their tags.
#
# The list used to be one inline regex with no mechanical owner, which made every entry a
# permanent grant: nothing could tell you when the gap it covered had been closed, and a
# filter that outlives its gap quietly stops the gate comparing real output.
KNOWN_FILE="$REPO/tools/transcript_known.txt"
[ -r "$KNOWN_FILE" ] || {
    echo "upstream-transcript: cannot read $KNOWN_FILE -- the declared-divergence list is the" >&2
    echo "upstream-transcript: gate's only allowance; without it every case would read as a" >&2
    echo "upstream-transcript: failure. Refusing." >&2; exit 2; }

K_TAG=(); K_PAT=(); K_HIT=()
while IFS=$'\t' read -r tag pat; do
    case "$tag" in
    '#'*|'') continue ;;
    esac
    if [ -z "${pat:-}" ]; then
        echo "upstream-transcript: UNTAGGED entry '$tag' -- every line needs EXPIRING or" >&2
        echo "upstream-transcript: PERMANENT and a tab before its pattern." >&2; exit 2
    fi
    case "$tag" in
    EXPIRING|PERMANENT) ;;
    *) echo "upstream-transcript: unknown tag '$tag' (want EXPIRING or PERMANENT)" >&2; exit 2 ;;
    esac
    K_TAG+=("$tag"); K_PAT+=("$pat"); K_HIT+=(0)
done < "$KNOWN_FILE"

# Guard the EXTRACTION, not just the verdict. A list read as empty makes every declared
# divergence an unknown one, so the gate would fail loudly rather than pass -- but a list read
# as empty because the FORMAT changed is a rig fault, and saying so beats 96 spurious diffs.
[ "${#K_PAT[@]}" -gt 0 ] || {
    echo "upstream-transcript: read 0 entries from $KNOWN_FILE -- the format changed and the" >&2
    echo "upstream-transcript: extraction lost its subject. Refusing." >&2; exit 2; }

# Join the patterns for the fast per-case filter; the per-entry accounting below is what
# decides whether each one is still earning its place.
KNOWN_RE="$(printf '%s|' "${K_PAT[@]}")"; KNOWN_RE="(${KNOWN_RE%|})"

pass=0; fail=0; known=0; rig=0

# Read a case's `# hold <seconds>` declaration, if it carries one. Both engines skip the line
# as a comment (upstream uci.cpp:184 and this tree's own comment arm), so the budget lives
# beside the search that needs it rather than in a table here.
#
# A header that does not parse answers UNPARSABLE rather than falling back to the default
# close, which would silently truncate the one case it was written for.
case_hold() {
    local script="$1" line
    while IFS= read -r line; do
        case "$line" in '# hold'*) ;; *) continue ;; esac
        if [[ "$line" =~ ^'# hold '([0-9]+)$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf 'UNPARSABLE'; fi
        return
    done <<<"$script"
}

# Drive ONE engine over one case script and leave its raw transcript in $6.
#
# WITHOUT a hold the pipe closes as soon as the script is written, which is what every case
# that declares none wants: each ends in `quit`, and the `stop` and `ponderhit` cases need
# the close to land while their first search is still running.
#
# WITH one the hold is a DEADLINE, not a sleep: the writer closes as soon as the engine has
# answered, and sets DRIVE_LATE if the deadline arrived first. A flat sleep long enough for
# the ten-million-node case would cost every other case the same wall clock, and a close that
# arrives early is worse than slow -- each engine then stops wherever its own thread got to,
# so the diff compares two truncations. `bestmove` cannot report that: closing stdin IS a
# `quit`, and a stopped search announces a bestmove too, so the two truncations diff clean
# and the case reads as agreement. DRIVE_LATE, not the `bestmove` line, is the signal.
DRIVE_LATE=0
drive() {
    local dir="$1" bin="$2" script="$3" prefix="$4" hold="$5" out="$6"
    DRIVE_LATE=0
    : >"$out"

    if [ -z "$hold" ]; then
        (cd "$dir" && printf '%s' "$script" | $prefix timeout 60 "$bin" 2>&1) >"$out"
        return
    fi

    local fifo line start rem
    fifo="$(mktemp -u "${TMPDIR:-/tmp}/zfish-transcript.XXXXXX")"
    mkfifo "$fifo" || return
    # Give the engine a wall-clock ceiling above its own hold: the deadline below decides the
    # verdict, and `timeout` is only here so a wedged engine cannot hold the fifo open forever.
    exec 8< <(cd "$dir" && $prefix timeout "$((hold + 30))" "$bin" <"$fifo" 2>&1)
    exec 9>"$fifo"
    # Opening for write blocked until the reader opened, so both ends are held and the name
    # is no longer needed.
    rm -f "$fifo"

    printf '%s' "$script" >&9
    start=$SECONDS
    while :; do
        rem=$(( hold - (SECONDS - start) ))
        [ "$rem" -gt 0 ] || { DRIVE_LATE=1; break; }
        IFS= read -r -t "$rem" line <&8 || { DRIVE_LATE=1; break; }
        printf '%s\n' "$line" >>"$out"
        case "$line" in bestmove*) break ;; esac
    done
    exec 9>&-
    while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line" >>"$out"; done <&8
    exec 8<&-
}

run_case() {
    local label="$1" script="$2" prefix="${3:-}"
    local ours theirs delta unknown hold ours_raw theirs_raw ours_late theirs_late late

    hold="$(case_hold "$script")"
    if [ "$hold" = UNPARSABLE ]; then
        rig=$((rig + 1))
        printf '  RIG   %s -- unparsable `# hold` header; want `# hold <seconds>`\n' "$label"
        return
    fi

    ours_raw="$(mktemp)"; theirs_raw="$(mktemp)"
    drive "$OUR_DIR"   "$OUR_BIN"    "$script" "$prefix" "$hold" "$ours_raw";   ours_late=$DRIVE_LATE
    drive "$THEIR_DIR" "$ORACLE_BIN" "$script" "$prefix" "$hold" "$theirs_raw"; theirs_late=$DRIVE_LATE
    ours="$(normalise <"$ours_raw")"; theirs="$(normalise <"$theirs_raw")"
    rm -f "$ours_raw" "$theirs_raw"

    # A side that ran out of hold answered a truncation, and the diff below cannot tell.
    if [ "$ours_late" = 1 ] || [ "$theirs_late" = 1 ]; then
        if   [ "$ours_late" = 1 ] && [ "$theirs_late" = 1 ]; then late='both engines'
        elif [ "$ours_late" = 1 ]; then late='zfish'
        else late='the oracle'; fi
        rig=$((rig + 1))
        printf '  RIG   %s -- %s did not answer inside its %ss hold; the diff would compare truncations\n' \
            "$label" "$late" "$hold"
        return
    fi

    # TWO SILENCES ARE NOT AN AGREEMENT. Every path that blanks a side blanks it to the
    # empty string -- a `cd` that fails short-circuits the `&&`, an engine that dies before
    # its banner prints nothing, `timeout` kills both under load, and a `normalise` whose
    # filter goes wrong eats both. The equality below then holds, and the case is counted
    # `ok` having compared nothing. Refuse FIRST, and as a rig fault (exit 2) rather than a
    # diff: no transcript this gate cares about is legitimately empty on both sides.
    if [ -z "$ours" ] && [ -z "$theirs" ]; then
        rig=$((rig + 1))
        printf '  RIG   %s -- BOTH engines produced no output; nothing was compared\n' "$label"
        return
    fi

    if [ "$ours" = "$theirs" ]; then
        pass=$((pass + 1)); return
    fi

    delta="$(diff <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | grep -E '^[<>]')"
    # Account each declared entry against the lines it actually covers. An entry that covers
    # nothing across the whole matrix is stale, and only a per-entry count can see that -- the
    # joined filter above is satisfied by any ONE alternative matching.
    local line i
    while IFS= read -r line; do
        case "$line" in
        '<'*|'>'*) ;;
        *) continue ;;
        esac
        for i in "${!K_PAT[@]}"; do
            [[ "$line" =~ ${K_PAT[$i]} ]] && K_HIT[$i]=$(( K_HIT[i] + 1 ))
        done
    done <<<"$delta"

    unknown="$(printf '%s\n' "$delta" | grep -Ev "$KNOWN_RE" | grep -E '^[<>]')"

    if [ -z "$unknown" ]; then
        known=$((known + 1))
        printf '  known %s (%d declared line(s))\n' "$label" "$(printf '%s\n' "$delta" | grep -c .)"
        return
    fi

    fail=$((fail + 1))
    printf '  DIFF  %s\n' "$label"
    printf '%s\n' "$unknown" | sed 's/^/          /' | head -20
}

# ---- the matrix ------------------------------------------------------------------
# Cover the surfaces a port drifts on: the handshake and the whole option listing, every
# NumaPolicy shape (valid, malformed, and the ones that exercise str_to_size_t's rule),
# the thread/hash options, position setup and its error paths, and the report commands.
#
# SEARCH OUTPUT IS COMPARED AT `Threads 1` ONLY. Lazy SMP is nondeterministic in BOTH
# engines, and oversubscribing it makes that loud: `taskset -c 1` with Threads 4 gives
# upstream 1, 1, then 2 info lines over three runs of the same command. Comparing that
# would make the gate flaky and, worse, would teach a reader to ignore its failures.
# Multi-thread cases therefore exercise the option/info surface with `isready` and leave
# the search to the single-threaded cases, which are deterministic on both sides.

printf 'handshake + option listing\n'
run_case 'uci' 'uci
quit
'
run_case 'isready before anything' 'isready
quit
'

printf 'command surface: dispatch, comments, unknown tokens\n'
# Upstream's fallthrough is `!token.empty() && token[0] != '#'`, so a blank line and a
# `#` line are silently ignored while anything else is an Unknown-command report. The
# token set below is upstream's complete top-level dispatch chain (uci.cpp:107-181).
run_case 'comment line'        '# a comment
isready
quit
'
run_case 'comment with args'   '#setoption name Hash value 4
isready
quit
'
run_case 'empty line'          '
isready
quit
'
# Build the blank-but-not-empty line with ANSI-C quoting: written literally it is trailing
# whitespace, which the repo's pre-commit hook strips -- silently turning this case into a
# duplicate of the empty-line one above.
ws_only=$'   \t '
run_case 'whitespace-only'     "$ws_only
isready
quit
"
run_case 'unknown token'       'frobnicate
isready
quit
'
run_case 'unknown with args'   'frobnicate a b c
isready
quit
'
run_case 'leading spaces'      '   isready
quit
'
run_case 'tab-separated'       'setoption	name	Hash	value	4
isready
quit
'
run_case 'uppercase token'     'ISREADY
isready
quit
'
run_case 'stop, no search'     'stop
isready
quit
'
run_case 'ponderhit, no search' 'ponderhit
isready
quit
'
for helptok in help license --help --license; do
    run_case "$helptok" "$helptok
quit
"
done
run_case 'export_net no arg'   'export_net
quit
'
run_case 'd before a position' 'd
quit
'
run_case 'compiler'            'compiler
quit
'

printf 'go sub-tokens (parse_limits)\n'
for limit in 'depth 4' 'nodes 5000' 'movetime 40' 'mate 2' 'perft 3' \
             'wtime 400 btime 400 winc 10 binc 10' 'wtime 400 btime 400 movestogo 20' \
             'depth 3 searchmoves e2e4 d2d4'; do
    run_case "go $limit" "setoption name Threads value 1
position startpos
go $limit
quit
"
done
# Malformed arguments: upstream names the KEYWORD, not the value, and terminates.
for bad in 'depth abc' 'nodes xyz' 'movetime -' 'wtime q'; do
    run_case "go $bad (malformed)" "position startpos
go $bad
quit
"
done

printf 'position sub-tokens and error paths\n'
run_case 'position alone'      'position
isready
quit
'
run_case 'startpos'            'position startpos
d
quit
'
run_case 'startpos moves'      'position startpos moves e2e4 e7e5
d
quit
'
run_case 'fen only'            'position fen 4k3/8/8/8/8/8/8/4K3 w - - 0 1
d
quit
'
run_case 'fen + moves'         'position fen 4k3/8/8/8/8/8/8/4K3 w - - 0 1 moves e1e2
d
quit
'
run_case 'bad fen'             'position fen not_a_fen
d
quit
'
run_case 'fen missing'         'position fen
d
quit
'
run_case 'illegal move in list' 'position startpos moves e2e5
d
quit
'

printf 'setoption edge cases\n'
run_case 'setoption alone'     'setoption
isready
quit
'
run_case 'name, no value'      'setoption name Hash
isready
quit
'
run_case 'value, no name'      'setoption value 4
isready
quit
'
run_case 'unknown option'      'setoption name Nope value 1
isready
quit
'
run_case 'button option'       'setoption name Clear Hash
isready
quit
'
run_case 'multi-word name'     'setoption name Skill Level value 5
isready
quit
'
run_case 'bool true/false'     'setoption name UCI_Chess960 value true
setoption name UCI_Chess960 value false
setoption name Ponder value true
isready
quit
'
run_case 'out-of-range spin'   'setoption name Hash value 0
setoption name Hash value 999999999
setoption name MultiPV value 0
isready
quit
'

printf 'NumaPolicy shapes\n'
for value in auto hardware none system \
             '0-3' '0-1:2-3' '0-3,8:4-7' '5,7,9' '7' \
             '0 1,2' '0,x,2' '0,0' '3-0' '1-2-3' 'x' ' x' '+2' '-1' '' \
             '0-99999999999' '0-1::2-3'; do
    run_case "NumaPolicy='$value'" "setoption name NumaPolicy value $value
setoption name Threads value 4
isready
quit
"
done

printf 'NumaPolicy under a restricted affinity mask\n'
for mask in 0-3 4-7 0,2,4,6 1; do
    run_case "taskset $mask, default policy" 'setoption name Threads value 4
isready
quit
' "taskset -c $mask"
    run_case "taskset $mask, NumaPolicy 0-1" 'setoption name NumaPolicy value 0-1
setoption name Threads value 4
isready
quit
' "taskset -c $mask"
    run_case "taskset $mask, NumaPolicy 0-1, 1 thread + go" 'setoption name NumaPolicy value 0-1
setoption name Threads value 1
go depth 6
quit
' "taskset -c $mask"
done

printf 'threads / hash / clear\n'
run_case 'Threads=1 + go' 'setoption name Threads value 1
go depth 8
quit
'
# Keep the thread counts MODEST. A Worker is ~15.5 MB resident (measured: 208 MB at
# Threads 1, 317 MB at Threads 8), so `Threads 1024` -- the option's own maximum -- is
# ~16 GB per engine and ~32 GB for the pair this harness runs. That is enough to take down
# a WSL2 VM, so the upper end of the range is deliberately NOT exercised here; the option's
# min/max is covered by the `uci` listing diff, which compares the declared bounds.
for threads in 2 8 16; do
    run_case "Threads=$threads (option surface)" "setoption name Threads value $threads
isready
quit
"
done
run_case 'Hash resize + Clear Hash' 'setoption name Hash value 32
setoption name Clear Hash value
ucinewgame
isready
quit
'
run_case 'Hash out of range' 'setoption name Hash value 999999999
isready
quit
'
run_case 'unknown option' 'setoption name NotAnOption value 3
isready
quit
'

printf 'position setup and its error paths\n'
run_case 'startpos + moves + go' 'setoption name Threads value 1
position startpos moves e2e4 e7e5 g1f3
go depth 8
quit
'
run_case 'fen + go' 'setoption name Threads value 1
position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1
go depth 7
quit
'
run_case 'chess960' 'setoption name Threads value 1
setoption name UCI_Chess960 value true
position fen bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9
go depth 7
quit
'
run_case 'MultiPV' 'setoption name Threads value 1
setoption name MultiPV value 3
position startpos
go depth 7
quit
'

printf 'root currmove announcement\n'
# `info depth D currmove M currmovenumber N` (search_emit.zig:167) is printed by no other gate
# here. It fires only past ten million nodes: `bench` searches its whole suite in fewer, every
# golden is a short scripted session, and each case above ends in seconds -- delete the call and
# every one of them stays green. Reaching the threshold is the whole cost of this case, which is
# what `# hold` exists for.
#
# The `wl.thread_idx != 0` guard stays uncovered: this runs at `Threads 1`, where dropping it
# changes nothing, and a multi-threaded case is not diffable against the oracle at all.
run_case 'root currmove (11M nodes)' '# hold 150
setoption name Threads value 1
position startpos
go nodes 11000000
'

printf 'report commands\n'
run_case 'd (board)' 'position startpos moves d2d4
d
quit
'
run_case 'eval trace' 'position startpos
eval
quit
'
run_case 'go perft' 'position startpos
go perft 4
quit
'
run_case 'flip' 'position startpos moves e2e4
flip
d
quit
'

echo
# Print the DENOMINATOR, not just the tallies: "12 ok" is only legible against how many
# cases ran, and a reader cannot infer that from three counters that all shrink together.
printf 'upstream-transcript: %d ok, %d known-divergent, %d FAILED, %d rig (%d cases, oracle %s)\n' \
    "$pass" "$known" "$fail" "$rig" "$((pass + known + fail + rig))" "${SHA:0:8}"
# A rig fault is not a divergence, so it does not exit 1: 0 pass / 1 mismatch / 2 rig, the
# split the parity driver already uses. Check it FIRST -- a run that compared nothing must
# never report the verdict of the cases it did compare.
[ "$rig" -eq 0 ] || {
    echo "upstream-transcript: REFUSING -- $rig case(s) compared nothing trustworthy." >&2
    echo "                     Check that both binaries run: $OUR_BIN in $OUR_DIR," >&2
    echo "                     $ORACLE_BIN in $THEIR_DIR; and that a case declaring a" >&2
    echo "                     \`# hold\` declares one its search can finish inside." >&2
    exit 2
}
[ "$fail" -eq 0 ] || exit 1

# EXPIRE THE ALLOWLIST. An EXPIRING entry that covered no line in the whole matrix is either a
# gap that has been closed -- delete the line and let the gate compare that output again -- or
# a pattern that has rotted, in which case it is no longer covering the divergence it names and
# a NEW one could hide behind the entry unnoticed. Both cases want the same action: look.
#
# PERMANENT entries are exempt by construction (they describe correct behaviour, so there is no
# day they retire), and every one of them carries its argument in transcript_known.txt.
stale=0
for i in "${!K_PAT[@]}"; do
    [ "${K_TAG[$i]}" = "EXPIRING" ] || continue
    [ "${K_HIT[$i]}" -gt 0 ] && continue
    echo "upstream-transcript: STALE declared divergence -- matched NOTHING in $((pass + known + fail)) case(s):"
    echo "                     ${K_PAT[$i]}"
    echo "                     Either the gap closed (delete the line) or the pattern rotted"
    echo "                     (fix it) -- while it sits there a NEW divergence can hide behind it."
    stale=$((stale + 1))
done
if [ "$stale" -ne 0 ]; then
    echo "upstream-transcript: $stale stale entr(ies) in tools/transcript_known.txt" >&2
    exit 1
fi
printf 'upstream-transcript: %d declared entr(y/ies), every one still earning its place\n' "${#K_PAT[@]}"
