const std = @import("std");

// Re-export the history and correction-table update formulas, which live in search_stats.zig
// (path-imported, so it stays inside this module). The seam is what a formula is for: the
// margins a node prunes and reduces by stay here, the numbers written back to the tables
// afterwards live there. Callers keep reading them off `search`.
const stats = @import("search_stats.zig");

pub const ttMoveHistoryDepthBonus = stats.ttMoveHistoryDepthBonus;
pub const ttMoveHistoryMatchBonus = stats.ttMoveHistoryMatchBonus;
pub const priorBonusScale = stats.priorBonusScale;
pub const priorScaledBonusBase = stats.priorScaledBonusBase;
pub const priorConthistScale = stats.priorConthistScale;
pub const priorMainhistScale = stats.priorMainhistScale;
pub const priorPawnhistScale = stats.priorPawnhistScale;
pub const captureStatScore = stats.captureStatScore;
pub const quietStatScore = stats.quietStatScore;
pub const correction_history_limit = stats.correction_history_limit;
pub const correctionHistoryBonus = stats.correctionHistoryBonus;
pub const multiCutCorrectionBonus = stats.multiCutCorrectionBonus;
pub const quietLowPlyScale = stats.quietLowPlyScale;
pub const quietContScale = stats.quietContScale;
pub const quietPawnScale = stats.quietPawnScale;
pub const conthistDelta = stats.conthistDelta;
pub const correctionValue = stats.correctionValue;
pub const statBonus = stats.statBonus;
pub const statMalus = stats.statMalus;

// Restate the value model rather than importing search_values.zig: Zig gives a file to ONE
// module, and search_driver already path-imports that one. Keep the two in step by hand.
const value_draw: i32 = 0;
const value_inf: i32 = 32001;
const value_none: i32 = 32002;
const max_ply: i32 = 246;
const value_mate: i32 = 32000;
const value_mate_in_max_ply: i32 = value_mate - max_ply;
const value_mated_in_max_ply: i32 = -value_mate_in_max_ply;
const value_tb: i32 = value_mate_in_max_ply - 1;
const value_tb_win_in_max_ply: i32 = value_tb - max_ply;
const value_tb_loss_in_max_ply: i32 = -value_tb_win_in_max_ply;

fn isValid(v: i32) bool {
    return v != value_none;
}

fn isWin(v: i32) bool {
    return v >= value_tb_win_in_max_ply;
}

fn isLoss(v: i32) bool {
    return v <= value_tb_loss_in_max_ply;
}

fn isMate(v: i32) bool {
    return v >= value_mate_in_max_ply;
}

fn isMated(v: i32) bool {
    return v <= value_mated_in_max_ply;
}

pub fn toCorrectedStaticEval(v: i32, cv: i32) i32 {
    const adjusted = v + @divTrunc(cv, 131072);
    return std.math.clamp(adjusted, value_tb_loss_in_max_ply + 1, value_tb_win_in_max_ply - 1);
}

pub fn valueDraw(nodes: usize) i32 {
    return value_draw - 1 + @as(i32, @intCast(nodes & 0x2));
}

// Adjust a mate or TB score to "plies to mate from the current position"
// before storing it in the transposition table. Standard scores are unchanged.
pub fn valueToTt(v: i32, ply: i32) i32 {
    if (isWin(v)) return v + ply;
    if (isLoss(v)) return v - ply;
    return v;
}

// Invert valueToTt(): adjust a mate/TB score read from the transposition
// table back to plies-from-root, downgrading potentially false mate/TB scores
// related to the 50-move rule and graph-history interaction.
pub fn valueFromTt(v: i32, ply: i32, r50c: i32) i32 {
    if (!isValid(v)) return value_none;

    // handle TB win or better
    if (isWin(v)) {
        // Downgrade a potentially false mate score.
        if (isMate(v) and value_mate - v > 100 - r50c)
            return value_tb_win_in_max_ply - 1;

        // Downgrade a potentially false TB score.
        if (value_tb - v > 100 - r50c)
            return value_tb_win_in_max_ply - 1;

        return v - ply;
    }

    // handle TB loss or worse
    if (isLoss(v)) {
        // Downgrade a potentially false mate score.
        if (isMated(v) and value_mate + v > 100 - r50c)
            return value_tb_loss_in_max_ply + 1;

        // Downgrade a potentially false TB score.
        if (value_tb + v > 100 - r50c)
            return value_tb_loss_in_max_ply + 1;

        return v + ply;
    }

    return v;
}

// Report whether the ROOT is already hunting a mate: at depth 16 or more with the current PV
// line's score past 2000. The depth condition on Step 9 is what finds mates, so it is not
// tunable -- but the question it was asked to answer, "is this line worth searching deep", is
// answered better at the root than per node. A LUT over abs(eval) + abs(beta) used to step the
// cutoff from 19 down to 13 (upstream fa8b6add); one root-level predicate that swaps 19 for 6
// finds the same mates through a far smaller tree, and it is the same predicate that stops the
// singular extension re-searching a line the root has already resolved.
pub fn seekMate(root_depth: i32, root_move_score: i32) bool {
    return root_depth >= 16 and absInt(root_move_score) >= 2000;
}

fn absInt(v: i32) i32 {
    return if (v < 0) -v else v;
}

// Bound Step 9's futility pruning: search to 6 while the root seeks a mate, 19 otherwise.
// Leave BOTH bounds alone when tuning -- the depth condition is what lets the search find
// mates at all, so a tuner that treats it as one more margin trades mates for Elo
// (upstream 074b1eac).
pub fn futilityDepth(seek_mate: bool) i32 {
    return if (seek_mate) 6 else 19;
}

// Prune child-node futility (Step 9): futilityMult = min(45 + depth*4, 85).
pub fn futilityMargin(
    depth: i32,
    tt_hit: bool,
    improving: bool,
    opponent_worsening: bool,
    correction_value: i32,
) i32 {
    var futility_mult: i32 = @min(45 + depth * 4, 85);
    futility_mult -= 20 * @as(i32, @intFromBool(!tt_hit));
    const imp: i32 = @intFromBool(improving);
    const opp: i32 = @intFromBool(opponent_worsening);
    const abs_corr = absInt(correction_value);
    return futility_mult * depth -
        @divTrunc((2789 * imp + 335 * opp) * futility_mult, 1024) +
        @divTrunc(abs_corr, 198435);
}

pub fn futilityReturn(beta: i32, eval: i32) i32 {
    return @divTrunc(661 * beta + 363 * eval, 1024);
}

// Prune quiet moves in the move loop: continuation-history prune threshold,
// parent-node futility value, and the negative-SEE margin.
pub fn historyPruneThreshold(depth: i32) i32 {
    return -4136 * depth;
}

pub fn quietFutilityValue(static_eval: i32, lmr_depth: i32, eval_gt_alpha: bool) i32 {
    return static_eval + 119 * lmr_depth + 90 * @as(i32, @intFromBool(eval_gt_alpha)) + 164;
}

pub fn quietSeeMargin(lmr_depth: i32) i32 {
    return 23 * lmr_depth * lmr_depth;
}

// Adjust the LMR reduction (r) before the reduced search.
pub fn lmrTtpvReduction(pv_node: bool, value_gt_alpha: bool, depth_ge: bool, cut_node: bool) i32 {
    return 3023 + @as(i32, @intFromBool(pv_node)) * 1004 +
        @as(i32, @intFromBool(value_gt_alpha)) * 885 +
        @as(i32, @intFromBool(depth_ge)) * (816 + @as(i32, @intFromBool(cut_node)) * 940);
}

pub fn lmrCorrReduction(correction_value: i32) i32 {
    const a = absInt(correction_value);
    return @divTrunc(a, 26310);
}

pub fn lmrStatScoreReduction(stat_score: i32) i32 {
    return @divTrunc(stat_score * 439, 4096);
}

// Scale the reduction by how far alpha sits from the node's eval -- upstream 5f7348f0.
// A larger r is a SHALLOWER search, so this reduces more when alpha is above the eval and
// less when it is below, bounded at 3*96 and 3*64. Quiet moves only, and only while alpha
// is non-decisive: inside the mate range the difference is not a margin.
pub fn lmrLooseAlphaReduction(alpha: i32, eval: i32) i32 {
    return 3 * std.math.clamp(alpha - eval, -64, 96);
}

pub fn lmrAllNodeScale(r: i32, depth: i32) i32 {
    return @divTrunc(r * 276, 256 * depth + 268);
}

// Compute the singular extension margins. corrValAdj = abs(correctionValue)/198368 is
// shared by both margins.
fn corrValAdj(correction_value: i32) i32 {
    const a = absInt(correction_value);
    return @divTrunc(a, 198368);
}

pub fn singularBeta(tt_value: i32, ttpv_and_not_pv: bool, depth: i32) i32 {
    return tt_value - @divTrunc((59 + 66 * @as(i32, @intFromBool(ttpv_and_not_pv))) * depth, 63);
}

pub fn singularDoubleMargin(pv_node: bool, not_tt_capture: bool, correction_value: i32, tt_move_history: i32, ply_gt_root: bool) i32 {
    return -2 + 204 * @as(i32, @intFromBool(pv_node)) - 152 * @as(i32, @intFromBool(not_tt_capture)) -
        corrValAdj(correction_value) - @divTrunc(1175 * tt_move_history, 114178) -
        @as(i32, @intFromBool(ply_gt_root)) * 38;
}

pub fn singularTripleMargin(pv_node: bool, not_tt_capture: bool, ttpv: bool, correction_value: i32, ply_gt_root: bool) i32 {
    return 70 + 279 * @as(i32, @intFromBool(pv_node)) - 188 * @as(i32, @intFromBool(not_tt_capture)) +
        81 * @as(i32, @intFromBool(ttpv)) - corrValAdj(correction_value) -
        @as(i32, @intFromBool(ply_gt_root)) * 43;
}

// Prune captures in the move loop: futility value (piece_value is the
// piece-value lookup, passed in) and the SEE pruning margin.
pub fn captureFutilityValue(static_eval: i32, lmr_depth: i32, piece_value: i32, capt_hist: i32) i32 {
    return static_eval + 234 + 247 * lmr_depth + piece_value + @divTrunc(134 * capt_hist, 1024);
}

pub fn captureSeeMargin(depth: i32, capt_hist: i32) i32 {
    // upstream e4a635486: drop the max(..,0) clamp.
    return 177 * depth + @divTrunc(capt_hist * 34, 1024);
}

// Prune by late move count: skip quiets once moveCount reaches this limit.
pub fn moveCountLimit(depth: i32, improving: bool) i32 {
    return @divTrunc(3 + depth * depth, 2 - @as(i32, @intFromBool(improving)));
}

// Compute the Step 12 ProbCut beta thresholds (shallow probcut and the deep TT cutoff).
pub fn probCutBeta(beta: i32, improving: bool) i32 {
    return beta + 241 - 64 * @as(i32, @intFromBool(improving));
}

pub fn probCutBetaDeep(beta: i32) i32 {
    return beta + 428;
}

// Prune with the null move (Step 10): static-eval cutoff threshold, dynamic reduction R,
// and the verification-search nmpMinPly.
pub fn nullMoveThreshold(beta: i32, depth: i32, improving: bool) i32 {
    return beta - 13 * depth - 47 * @as(i32, @intFromBool(improving)) + 365;
}

// Deepen the null-move reduction when the static eval already towers over beta:
// the more the position is winning, the less the null search needs to prove.
// C++ `(ss->staticEval - beta) / 256` truncates toward zero, so use @divTrunc;
// the clamp to 0 makes the two rounding directions agree anyway.
pub fn nullMoveReduction(depth: i32, static_eval: i32, beta: i32) i32 {
    return 7 + @divTrunc(depth, 3) + @max(@divTrunc(static_eval - beta, 256), 0);
}

// Gate Step 10 on beta being outside the decisive range. This margin is stricter
// than `!is_loss(beta)` so that the static-eval-scaled reduction above cannot
// cost a mate find.
pub fn nullMoveBetaOk(beta: i32) bool {
    return beta >= -2000;
}

pub fn nmpMinPly(ply: i32, depth: i32, r: i32) i32 {
    return ply + @divTrunc(3 * (depth - r), 4);
}

// Compute the Step 8 razoring threshold subtracted from alpha (search()).
pub fn razorMargin(depth: i32) i32 {
    return 482 * depth * depth;
}

// Blend the qsearch beta-trend: when a non-decisive bestValue clears beta it is
// pulled partway toward beta. Step 4 stand-pat uses 441/583; the pre-TT-store
// fail-high path uses 462/562. Both divide by 1024 with toward-zero truncation.
pub fn qsearchStandPatBlend(best_value: i32, beta: i32) i32 {
    return @divTrunc(441 * best_value + 583 * beta, 1024);
}

pub fn qsearchFailHighBlend(best_value: i32, beta: i32) i32 {
    return @divTrunc(462 * best_value + 562 * beta, 1024);
}

// Order quiets by static-eval difference (search(), after the moves_loop check
// guard): clamp the negated sum of the previous and current static evals into
// [-189, 194] and bias by 60. The caller scales it (*10, *13) into history.
pub fn evalDiff(prev_static_eval: i32, static_eval: i32) i32 {
    return @max(@as(i32, -189), @min(@as(i32, 194), -(prev_static_eval + static_eval))) + 60;
}

// Compute the qsearch futility base = static eval plus a fixed margin. The move loop later
// adds the captured piece value to this base.
pub fn qsearchFutilityBase(static_eval: i32) i32 {
    return static_eval + 306;
}

// Size the aspiration window in iterative_deepening(). The starting half-width
// mixes a base, a per-thread stagger, and the root move's mean-squared score;
// on each fail high/low it grows by 47/128.
pub fn aspirationInitialDelta(thread_idx: usize, mean_squared_score: i32) i32 {
    const tmod: i32 = @intCast(thread_idx % 8);
    const abs_mss = absInt(mean_squared_score);
    return 5 + tmod + @divTrunc(abs_mss, 10193);
}

pub fn aspirationDeltaGrow(delta: i32) i32 {
    return delta + @divTrunc(47 * delta, 128);
}

// Compute eval optimism from the root move's average score (iterative_deepening()):
// a saturating 114*avg/(|avg|+85). The caller mirrors it for the opponent.
pub fn optimism(avg: i32) i32 {
    const abs_avg = absInt(avg);
    return @divTrunc(114 * avg, abs_avg + 85);
}

// Populate the reductions[] lookup table: reductions[i] = int(2872/128.0 * ln i)
// for i in [1, count). Index 0 is left untouched, matching upstream clear().
//
// The entry is u16 rather than i32 because the table is a SCALED LOGARITHM and so has no
// negative entry -- 22.4375 * ln(255) is 124, and there is nothing below it. Stored signed,
// that range is a fact no backend can use, and `reductionAcc`'s divide by 512 then had to
// allow for a negative dividend on every reduced move. See the comment there. The table also
// halves, 1024 bytes to 512, which nothing here measures.
pub fn fillReductions(reductions_ptr: [*]u16, count: usize) void {
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const logv = @log(@as(f64, @floatFromInt(i)));
        reductions_ptr[i] = @intFromFloat(2872.0 / 128.0 * logv);
    }
}

// --- tests --------------------------------------------------------------
test "valueToTt / valueFromTt: mid-range scores pass through unchanged" {
    try std.testing.expectEqual(@as(i32, 500), valueToTt(500, 7));
    try std.testing.expectEqual(@as(i32, -500), valueToTt(-500, 7));
    try std.testing.expectEqual(@as(i32, 500), valueFromTt(500, 7, 50));
}

test "toCorrectedStaticEval: correction is a >>17 add, then clamp" {
    try std.testing.expectEqual(@as(i32, 300), toCorrectedStaticEval(300, 0));
    try std.testing.expectEqual(@as(i32, 301), toCorrectedStaticEval(300, 131072)); // +1
    try std.testing.expectEqual(@as(i32, 300), toCorrectedStaticEval(300, 131071)); // <131072 -> +0
}

// Pin the two Step 10 / Step 16 margins at the boundaries their formulas turn on. Both are
// pure integer functions carrying upstream's tuned constants, and until now the only thing
// holding either was the bench node count -- which moves when they move, but cannot say
// WHICH term moved, and cannot tell a transcription slip from an intended retune at all.
test "nullMoveReduction: the excess is measured from beta and steps every 256" {
    // R = 7 + depth/3 + max((static_eval - beta) / 256, 0); depth 9 -> 7 + 3 = 10.
    try std.testing.expectEqual(@as(i32, 10), nullMoveReduction(9, 0, 0));
    try std.testing.expectEqual(@as(i32, 10), nullMoveReduction(9, 255, 0)); // under the step
    try std.testing.expectEqual(@as(i32, 11), nullMoveReduction(9, 256, 0)); // exactly one step

    // The excess is relative to beta, not to zero: 700 - 100 = 600 -> +2.
    try std.testing.expectEqual(@as(i32, 12), nullMoveReduction(9, 700, 100));

    // A static eval BELOW beta must never shorten R. @divTrunc would hand back a negative
    // term here, so the @max(.., 0) is what stops a losing node from being searched deeper
    // than an equal one.
    try std.testing.expectEqual(@as(i32, 10), nullMoveReduction(9, -5000, 0));
}

test "seekMate: both conditions bind, and the score is read by magnitude" {
    // Each threshold, read either side of it.
    try std.testing.expect(!seekMate(15, 2000));
    try std.testing.expect(seekMate(16, 2000));
    try std.testing.expect(!seekMate(16, 1999));

    // A root move being MATED counts the same as mating: the sign must not matter.
    try std.testing.expect(seekMate(16, -2000));
    try std.testing.expectEqual(seekMate(20, 3000), seekMate(20, -3000));

    // A root move that has no score yet (-VALUE_INFINITE) reads as a mate hunt, which is
    // upstream's behaviour: the first PV line is scored before depth ever reaches 16.
    try std.testing.expect(seekMate(16, -value_inf));

    // The two cutoffs Step 9 chooses between.
    try std.testing.expectEqual(@as(i32, 19), futilityDepth(false));
    try std.testing.expectEqual(@as(i32, 6), futilityDepth(true));
}

test "fillReductions: log-scaled, index 0 untouched, monotonic from 1" {
    var r: [64]u16 = undefined;
    // A sentinel index 0 cannot be negative any more, which is the point of the retype --
    // so pick one the fill would never write. It writes 0 at index 1 and rises from there.
    r[0] = 999;
    fillReductions(&r, 64);
    try std.testing.expectEqual(@as(u16, 999), r[0]); // loop starts at i=1
    try std.testing.expectEqual(@as(u16, 0), r[1]); // log(1) == 0
    try std.testing.expect(r[63] > r[2]);
    var i: usize = 2;
    while (i < 64) : (i += 1) try std.testing.expect(r[i] >= r[i - 1]);
}

test "fillReductions: no entry leaves u16, over the whole indexable range" {
    // The retype rests on the table having no negative entry AND no entry past 65535: it is
    // 2872/128 * ln(i), so the largest index the search can reach decides. Check the whole
    // 256-entry table the worker holds rather than the 64 the test above uses -- the bound
    // that matters is the one at MAX_MOVES, not at 64.
    var r: [256]u16 = undefined;
    fillReductions(&r, 256);
    try std.testing.expectEqual(@as(u16, 124), r[255]);
    // ... and that reductionAcc's product stays inside u32, which is what lets the
    // improving term be an unsigned shift rather than a rounded signed divide.
    const widest: u32 = @as(u32, r[255]) * @as(u32, r[255]) * 197;
    try std.testing.expect(widest < std.math.maxInt(u32));
}
