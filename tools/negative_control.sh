#!/usr/bin/env bash
# negative-control: prove each correctness gate can actually FAIL.
#
# Every gate's power to detect a defect is otherwise an assumption. This tree runs that
# experiment by hand at the moment a gate is written and never again -- and a gate that has
# quietly stopped being able to fail is invisible in exactly the way a missing test is not:
# a missing test shows up in a coverage discussion, a passing one does not.
#
# One behavioural mutation per gate: apply it, require the gate to go RED, restore the file,
# require it to go GREEN again. One representative mutant rather than a mutant set -- the
# competent-programmer hypothesis is what makes a single mutation worth gating on (Jia &
# Harman, "An Analysis and Survey of the Development of Mutation Testing", IEEE TSE 37(5)).
#
# PERTURB THE VALUE, DO NOT REMOVE THE BOUND. A mutant aimed at an evaluation or a search
# margin must leave the search a ceiling, or the experiment cannot end -- and a gate that
# never returns is not a gate that failed. The sibling port learnt this the expensive way:
# inverting an activation clamp handed the search an evaluation with no ceiling and its gate
# ran past 900s twice, once for over 25 minutes. Every row here scales a value or removes one
# generated move; each leaves a sane engine searching a different tree.
#
# FOUR WAYS THIS RIG CAN LIE, and every one exits 2 -- NO VERDICT -- rather than scoring
# itself. Each was verified by forcing it:
#   * a pattern that has ROTTED matches nothing, leaves the tree unmutated, and lets the gate
#     go green -- which reads as "the gate failed to detect it". Every row asserts the file
#     actually changed.
#   * a mutant that HANGS is not a gate that failed. Each gate run is bounded, and a timeout
#     is reported as a rig fault.
#   * a gate that was ALREADY RED proves nothing by going red under mutation, so every gate in
#     the run must be green before anything is touched.
#   * a mutation LEFT BEHIND poisons every gate that runs afterwards, so each mutated file is
#     compared against its own backup at the end.
#
# NOT A BUILD STEP, deliberately. It drives `zig build` itself, and a nested `zig build`
# inside a build step contends on the build cache -- measured here: the identical command
# exits 0 standalone and 1 from inside a step. So it is invoked directly, and CI invokes it
# the same way.
#
# Usage:  tools/negative_control.sh [<gate> ...]     # default: every row
#         tools/negative_control.sh --list
# Exit:   0 every gate detected its mutation, 1 a gate did NOT, 2 a rig fault.
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
# A failed cd would mutate paths relative to whatever directory the caller was in.
cd "$REPO" || exit 2

# Bound each gate run. The clean runs below measure well under this; the margin is for a cold
# rebuild, which every engine mutation forces.
TIMEOUT="${NEGCTL_TIMEOUT:-900}"

BACKUP_DIR="$(mktemp -d)"
restore_all() {
    local f rel
    while IFS= read -r -d '' f; do
        rel="${f#"$BACKUP_DIR"/}"
        cp "$f" "$REPO/$rel" 2>/dev/null || true
    done < <(find "$BACKUP_DIR" -type f -print0 2>/dev/null)
    rm -rf "$BACKUP_DIR"
}
# An EXIT trap, not a tidy-up at the end: a run killed mid-mutation must still put the tree
# back. Cover the signals a CI cancel and a Ctrl-C actually send.
trap restore_all EXIT INT TERM

# --- the rows -----------------------------------------------------------------------------
# gate | file | literal to find | replacement | what the mutation means
#
# A row's `find` must be a literal that appears EXACTLY ONCE. `apply` asserts both that it
# matched and that the file changed, so a row whose subject was renamed is a rig fault rather
# than a silent pass.
ROWS=(
    # The anchor. Scale the razoring threshold by one: the search still converges, it just
    # searches a different tree, so the bench total moves off 2497913.
    "signature|src/engine/search/search.zig|    return 482 * depth * depth;|    return 483 * depth * depth;|razor margin 482->483"
    # The specified oracle. Stop generating knight under-promotions: perft counts are facts
    # about chess, so this is the one gate whose reference cannot be re-blessed past a bug.
    "perft|src/engine/board/movegen.zig|        writer.push(makeSpecialMove(promotion, from, to, knight));\n|:DELETE:|movegen omits knight under-promotion"
    # A characterization golden over a print path. Shift the file letter the `d` command
    # renders checkers with: the in-check row reads \`Checkers: i4\` instead of \`h4\`.
    "misc|src/shell/engine/util.zig|@as(u8, 'a') + @as(u8, @intCast(square % 8)),|@as(u8, 'b') + @as(u8, @intCast(square % 8)),|d renders checkers one file off"
    # The structural lint. Name a path that is not in the tree -- the rot class docs-lint
    # exists for, and the one no value gate can see.
    "docs-lint|docs/10-tooling-ci.md|## The NNUE net and tablebases|Mutant claim about \`src/no_such_file_negative_control.zig\`.\n\n## The NNUE net and tablebases|a doc names a path that is not in the tree"
    # The protocol invariant, on the path no golden can photograph. Answer an idle `stop`
    # with a bestmove: every value gate reads identically, because the transcripts they diff
    # never send a `stop` the engine is awake to hear.
    "parity-async|src/shell/uci.zig|        .stop => {\n|        .stop => {\n            uci_output.printLine(\"bestmove e2e4\");\n|an idle \`stop\` answers with a bestmove"
    # The lane lint, on the half that reads ORDER rather than presence. Run zig one step above
    # the install: every step named in the job is still dispatched, so the older half of this
    # gate and every value gate read identically -- which is exactly how the weekly upstream
    # job came to die at exit 127 with nothing in the tree able to see it.
    "lane-coverage|.github/workflows/zfish_perft.yml|      - uses: mlugg/setup-zig@|      - run: zig version\n      - uses: mlugg/setup-zig@|a job runs zig one step above its install"
    # The hostile-input battery. Take the shift-width refusal out of the tablebase header
    # parse: a raw file byte then reaches `1 << n` with n up to 255. Every value gate reads
    # identically, because the bench and every golden read only files the engine shipped with
    # -- which is precisely why this class of bound had nothing gating it before.
    "parity-malformed|src/platform/syzygy/decode_header.zig|    if (buf[p] >= 64 or buf[p + 1] >= 64) return error.CorruptTable;\n|:DELETE:|the tablebase shift-width refusal is removed"
    # The hang gate. Put the lower bound on `movetime` back to zero, which is what the UCI
    # parser did before 160a4a5c: `checkTime` reads `lim_movetime != 0`, so zero stops meaning
    # "stop at once" and starts meaning "there is no limit". Every value gate reads identically
    # -- none of them sends `movetime 0`, and a search that never ends produces no line to
    # diff. It is only a HANG, which is the one thing the rest of this battery cannot express.
    "liveness|src/shell/uci_parse.zig|clampClock(&notice, allocator, \"movetime\", v, 1)|clampClock(&notice, allocator, \"movetime\", v, 0)|a movetime of zero stops bounding the search"
    # The type gate. Give NodeKind the fourth variant it exists to forbid -- a non-PV root,
    # which no call site produces and no meaning names. Nothing else can see it: adding an
    # unused enum variant changes no value, so every golden, the anchor and the whole search
    # read identically. It is a widened DOMAIN, which is the class this gate was added for.
    "type-refusal|src/engine/search/search_types.zig|pub const NodeKind = enum {\n|pub const NodeKind = enum {\n    non_pv_root,\n|NodeKind regains the fourth variant it forbids"
    # The arena lifecycle, on the surface BOTH leak checkers stopped seeing. Never give a
    # large-page block back. memcheck reports a definite leak only for allocations it
    # intercepts and an anonymous mapping is not one, so `parity-valgrind` and
    # `parity-teardown` read identically over a build that releases no arena at all -- which
    # is exactly the coverage the mmap port took away and `liveLargePageBlocks` gives back.
    # A sibling made the same mutation a permanent row rather than a thing done once, which
    # is the difference between a gate and a memory of having checked.
    "test|src/platform/memory.zig|pub fn alignedLargePagesFree(ptr: ?*anyopaque) void {\n|pub fn alignedLargePagesFree(ptr: ?*anyopaque) void {\n    if (@import(\"builtin\").mode != .Debug) return;\n|a large-page arena is never given back"
)

if [ "${1:-}" = "--list" ]; then
    for row in "${ROWS[@]}"; do IFS='|' read -r gate _ _ _ desc <<<"$row"; printf '%-12s %s\n' "$gate" "$desc"; done
    exit 0
fi

WANTED=("$@")
wanted() {
    [ ${#WANTED[@]} -eq 0 ] && return 0
    local w; for w in "${WANTED[@]}"; do [ "$w" = "$1" ] && return 0; done
    return 1
}

# Apply one literal replacement and PROVE it landed. `:DELETE:` removes the match.
apply() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
path, find, repl = sys.argv[1], sys.argv[2], sys.argv[3]
find = find.encode().decode("unicode_escape")
repl = "" if repl == ":DELETE:" else repl.encode().decode("unicode_escape")
p = pathlib.Path(path)
if not p.exists():
    print(f"    the row's FILE does not exist: {path}", file=sys.stderr); sys.exit(3)
before = p.read_text()
n = before.count(find)
if n != 1:
    print(f"    the row's pattern matched {n} time(s), expected exactly 1", file=sys.stderr); sys.exit(3)
after = before.replace(find, repl)
if after == before:
    print("    the replacement left the file unchanged", file=sys.stderr); sys.exit(3)
p.write_text(after)
PY
}

fail_rig() { printf '  RIG   %s -- %s\n' "$1" "$2"; printf '        This is a RIG FAULT, not a gate verdict.\n'; RIG=$((RIG + 1)); }

DETECTED=0; MISSED=0; RIG=0; RAN=0
MUTATED=()

printf 'negative-control: bounded at %ss per gate run\n' "$TIMEOUT"

# A red tree makes the whole experiment meaningless: "the gate went red under mutation" says
# nothing if it was red already. Establish green FIRST, for every gate in this run.
for row in "${ROWS[@]}"; do
    IFS='|' read -r gate _ _ _ _ <<<"$row"
    wanted "$gate" || continue
    if ! timeout "$TIMEOUT" zig build "$gate" >/dev/null 2>&1; then
        fail_rig "$gate" "the gate is RED BEFORE any mutation; nothing here would mean anything"
    fi
done
[ "$RIG" -eq 0 ] || { printf 'negative-control: REFUSED -- %d gate(s) not green to begin with\n' "$RIG"; exit 2; }

for row in "${ROWS[@]}"; do
    IFS='|' read -r gate file find repl desc <<<"$row"
    wanted "$gate" || continue
    RAN=$((RAN + 1))

    mkdir -p "$BACKUP_DIR/$(dirname "$file")"
    cp "$file" "$BACKUP_DIR/$file"
    MUTATED+=("$file")

    if ! apply "$file" "$find" "$repl"; then
        fail_rig "$gate" "the mutation did not apply ($file)"
        continue
    fi

    timeout "$TIMEOUT" zig build "$gate" >/dev/null 2>&1
    rc=$?

    cp "$BACKUP_DIR/$file" "$file"

    if [ "$rc" -eq 124 ]; then
        fail_rig "$gate" "the mutant did not terminate within ${TIMEOUT}s -- perturb the value, do not remove the bound"
    elif [ "$rc" -ne 0 ]; then
        printf '  ok    %-12s %-44s red (%d)\n' "$gate" "$desc" "$rc"
        DETECTED=$((DETECTED + 1))
    else
        printf '  MISS  %-12s %-44s STAYED GREEN\n' "$gate" "$desc"
        printf '        The gate cannot detect this defect. It is not gating what it claims to.\n'
        MISSED=$((MISSED + 1))
    fi
done

# Prove the tree came back. A harness that leaves a mutation behind poisons every later gate,
# and the restore is the part nobody checks.
#
# Compare each mutated file against ITS OWN backup, not `git diff` over the tree: this runs on
# a working tree that legitimately has other edits -- it was written on one -- and asking git
# about everything reported a rig fault for changes the harness never touched. A gate that
# cannot pass while you are working is a gate you stop running.
for f in ${MUTATED[@]+"${MUTATED[@]}"}; do
    cmp -s "$BACKUP_DIR/$f" "$f" || {
        printf 'negative-control: %s was NOT restored -- the mutation is still in the tree\n' "$f"
        printf '                  restore it from git before running any other gate.\n'
        exit 2
    }
done
for row in "${ROWS[@]}"; do
    IFS='|' read -r gate _ _ _ _ <<<"$row"
    wanted "$gate" || continue
    timeout "$TIMEOUT" zig build "$gate" >/dev/null 2>&1 ||
        fail_rig "$gate" "still RED after restore -- the tree did not come back"
done

if [ "$RIG" -ne 0 ]; then
    printf 'negative-control: %d rig fault(s) -- no verdict\n' "$RIG"; exit 2
fi
if [ "$MISSED" -ne 0 ]; then
    printf 'negative-control: %d of %d gate(s) detected their mutation, %d MISSED\n' "$DETECTED" "$RAN" "$MISSED"; exit 1
fi
printf 'negative-control: %d of %d gate(s) detected their mutation, tree restored and green\n' "$DETECTED" "$RAN"
