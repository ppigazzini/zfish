# Upstream sync log

Per-phase progress resyncing the native Zig port to upstream Stockfish. Plan: `../../../__DEV/reports/REPORT-13-FETCH-UPSTREAM.md`.
Delta: `UPSTREAM_BASE` (dd321af5d, net nn-83a0d6daf7e5, Bench 2336177) → `UPSTREAM_TARGET` (4488343cf, net nn-af1339a6dea3, Bench 2102535).

**Bit-exactness baseline (verified 2026-06-29):** upstream@base `dd321af5d` carries `Bench: 2336177`,
identical to our native default bench → the Zig port is bit-exact to upstream at the base. Every later
commit is a delta from this known-good point.

---

## Phase A — tooling + pristine oracle  ✅ (commit 26f73e697)
Stood up upstream_oracle.sh / upstream_benchmap.sh / upstream_router.py / upstream_parity.sh + tracked
state. Pristine oracle verified: HEAD benches 2102535. Backlog: HIGH=31 MED=13 LOW=2 SKIP=25.

## Phase B — mechanical / no-bench-move commits  ✅ (audit, no Zig change required)
All 10 candidates carry **no `Bench:` line** (non-functional by SF convention) and were verified to
require **zero native-port changes** — our reimplementation does not mirror C++ type decls, and the
result of every touched computation is unchanged (bench-invariant). Absorbed for free; the port remains
bit-exact at 2336177.

| commit | subject | why no-op for the native build |
|---|---|---|
| dd3e1c4a5 | Consistent Integer Types | u8/u16/usize renames + std::array on the **magic** tables; our bitboard.zig has no magics (computes attacks on the fly) — same attack results |
| 6e4e03fd2 | Replace Remaining Types | size_t→usize renames; pure C++ typing |
| 718a001e6 | Fixup RelaxedAtomic operator Types | atomic-wrapper typing; Zig atomics are separate |
| 0111d11e2 | Disable perf-sensitive relaxed atomics at compile time | adds an opt-out macro; default path (relaxed) unchanged |
| 133731f33 | Simplify away unused CorrHistType variants | removes an **unused** corrhist variant — no behavioral effect |
| 24d639849 | Move Attacks out of Bitboard File | pure file split (new src/attacks.cpp/.h); our attacks live in bitboard.zig |
| 92fe6b6f4 | Simplify RankAttacks initialization | init-time refactor, identical table |
| 9eb836b3b | Compute simplified HQ r/rr at runtime | Hyperbola-Quintessence micro-opt, identical attack sets |
| f9beec5fa | Reuse computed ray bitboard in update_piece_threats | micro-opt, identical threats |
| 57f3a2bfb | Replace directory == "<internal>" with else | UCI-internal control-flow tidy, same branches |

**Manifest upkeep:** added `src/attacks.cpp/.h` → `bitboard.zig` (24d639849 introduced the file split) so
future commits touching attacks route correctly.

**Gates (mfinal worktree):** signature 2336177, perft, perft-parity, oracle-parity, output-golden — all OK.

**Marker NOT advanced:** these commits interleave chronologically with functional ones (Phase C/D/E) not
yet ported, so `UPSTREAM_BASE` stays at dd321af5d until the contiguous prefix through TARGET is bit-exact.

---

## Phase C — position correctness  ✅
6 candidates audited; our reimplementation already avoided 5 of them. **Exactly one real fix ported.**

| commit | subject | outcome |
|---|---|---|
| **782852b26** | Clear capturedPiece in do_null_move | **PORTED** — our `doNullMove` copied the prior StateInfo (stale `captured_piece`) and never cleared it; added `pos.st.captured_piece = 0`. Affects prior_capture detection after null moves. |
| 86f1df713 | Fix material key computation error | **no change** — our do_move moves the piece *first* (post-move pieceCount) and uses `[8+count-1]`(prom)/`[8+count]`(pawn), yielding the same correct slots (8+M, 8+N−1) as upstream's fixed pre-move formula. Already correct. |
| 278a755fb | Reorder operations in do_move | **no change** — pure prefetch-timing/ordering perf; our piece-first ordering is valid and result-identical. |
| 5595cb20e | FEN validation pawns on rank 1/8 | **no change** — upstream bug was `RANK_1\|RANK_8` (enum values 0\|7) vs bitboards; our Zig already uses `rank1_bb\|rank8_bb`. Never had the bug. |
| 47575ebd8 | Dedup color-specific piece validation | **no change** — pure refactor (loop over colors), identical validation. |
| 1ece3c030 | Simplify evasion logic | **no change** — upstream delegates `pseudo_legal` under check to `MoveList<EVASIONS>.contains(m)`; our manual block/capture/king-safety checks are behavior-equivalent **and faster** (O(1) vs generating all evasions). Kept the equivalent. |

**Verification:** the one ported fix is bench-invariant — signature stayed 2336177; perft, perft-parity,
oracle-parity, output-golden, eval-trace all OK (regression guard intact). Marker not advanced (functional
commits still interleaved ahead).

## Phase D — NNUE accumulator-merge arch port  🚧 (in progress, branch RED vs base gates)
The hard one (7c7fe322e merge + fff35786b nnz + new net). Driven in sub-phases; **branch sits RED vs the
base-net gates until D completes bit-exact at the new net.** SIMD/nnz machinery is out of scope (perf only;
scalar dense compute is result-identical).

Useful finding from the Zig map: our reimplementation **already** does the "merged" transform math
(folds threat into the sum at transform time, clamps [0,255], pairwise-multiplies ÷512, halves PSQT) —
mathematically identical to the merged accumulator (associativity). So the merge is largely net-format.

### D1 — net format / parsing  ✅ (new net LOADS)
- `network_version` 0x7AF32F20 → **0x6A448AFA** (network.zig).
- FT read order (7c7fe322e): base packed the two i32 PSQT arrays into one leb section after `weights`;
  HEAD reads each as its OWN section, order `biases → threatWeights → threatPsqtWeights → weights →
  psqtWeights`. Reordered `parseFeatureTransformer` (nnue_parse.zig); storage offsets unchanged.
- Default net name → **nn-af1339a6dea3.nnue** in BOTH `engine.zig:59` (drives the EvalFile option /
  actual load) and `network.zig:21` (+ option.zig cosmetic/test). Net copied into src/.
- **Verified:** engine loads + parses the new net (`NNUE evaluation using nn-af1339a6dea3.nnue (106MiB,
  (83248,1024,31,32,1))`), runs eval + search without crashing. Successful parse proves version +
  read-order + LEB framing are correct (a wrong order desyncs the magic/count checks → rejection).
- Startpos eval: ours **−22** vs oracle **+10** (side-to-move, internal) — close, confirming D2+ is only
  the fine integer math, not the structure.

### D2 — propagate output scaling + activation shifts  ⏳ (next)
nnue_architecture.h changes: `fwdOut = fc2_out[0] + fc0_out[L2]` THEN scale by `600·OutputScale /
(HiddenOneVal·(1<<WSB)·2)` = `9600/16384` via i64 (ours: scales fc0_out[31] alone by `9600/8128`, then
adds fc2_out). Activation layers gained a shift param: ac_sqr_0/ac_0 use WSB+1, ac_1 uses WSB (ours uses
WSB throughout). Verify with eval-trace layer-by-layer vs the pristine oracle, then bench → 2102535.

## Phase E/F — search+TT tweaks, UCI/misc, reharden  ⏳
End bit-exact at 2102535; then advance UPSTREAM_BASE → 4488343cf.
