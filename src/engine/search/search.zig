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

// Look up the futility pruning cutoff depth (Step 8). The depth condition is what finds
// mates, so it is not tunable: the LUT holds the thresholds where
//     depth = 13 + int(0.5 + 6 / (1 + pow(abs(eval) + abs(beta), 3) / 50'000'000'000))
// steps down, so a bigger score on either side of the window prunes shallower and leaves
// the deep mating lines to be searched. The last entry is past any reachable
// |eval| + |beta| and is what stops the walk.
const futility_depth_lut = [7]i32{ 1657, 2555, 3294, 4122, 5314, 8194, 2 * value_inf };

comptime {
    // Prove the sentinel stops the walk rather than assuming it. The caller's `eval` is a
    // corrected static eval OR a transposition value, so only `abs(eval) <= value_mate`
    // holds -- the `!isWin(eval)` guard at the call site bounds the positive side alone --
    // and `beta` is a window bound, so `abs(beta) <= value_inf`. The shipped build checks no
    // array bound, and the walk would read PAST the table rather than fault: a value model
    // that outgrew this would come back as a plausible depth, which the anchor cannot see.
    if (futility_depth_lut[futility_depth_lut.len - 1] <= value_mate + value_inf)
        @compileError("futility_depth_lut needs a sentinel above the largest reachable abs(eval) + abs(beta)");
}

pub fn futilityDepth(eval: i32, beta: i32) i32 {
    const prob = absInt(eval) + absInt(beta);
    var depth: usize = 0;
    while (futility_depth_lut[depth] < prob) depth += 1;
    return 19 - @as(i32, @intCast(depth));
}

fn absInt(v: i32) i32 {
    return if (v < 0) -v else v;
}

// Prune child-node futility (Step 8): futilityMult = min(45 + depth*4, 85).
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

// Reduce less when alpha sits far above the static eval -- upstream 5f7348f0. A loose
// alpha window means the node is failing low by a wide margin, so the reduced search is
// less trustworthy; skipped for captures and for decisive alphas.
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

// Compute the Step 11 ProbCut beta thresholds (shallow probcut and the deep TT cutoff).
pub fn probCutBeta(beta: i32, improving: bool) i32 {
    return beta + 241 - 64 * @as(i32, @intFromBool(improving));
}

pub fn probCutBetaDeep(beta: i32) i32 {
    return beta + 428;
}

// Prune with the null move (Step 9): static-eval cutoff threshold, dynamic reduction R,
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

// Gate Step 9 on beta being outside the decisive range. This margin is stricter
// than `!is_loss(beta)` so that the static-eval-scaled reduction above cannot
// cost a mate find.
pub fn nullMoveBetaOk(beta: i32) bool {
    return beta >= -2000;
}

pub fn nmpMinPly(ply: i32, depth: i32, r: i32) i32 {
    return ply + @divTrunc(3 * (depth - r), 4);
}

// Compute the Step 7 razoring threshold subtracted from alpha (search()).
pub fn razorMargin(depth: i32) i32 {
    return 483 + 318 * depth * depth;
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
pub fn fillReductions(reductions_ptr: [*]i32, count: usize) void {
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

// Pin the two Step 9 / Step 15 margins at the boundaries their formulas turn on. Both are
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

test "futilityDepth: 19 down to 13, and the extremes stay inside the table" {
    // The steps themselves, read either side of each threshold.
    try std.testing.expectEqual(@as(i32, 19), futilityDepth(0, 0));
    try std.testing.expectEqual(@as(i32, 19), futilityDepth(1657, 0)); // the entry is the last <= it
    try std.testing.expectEqual(@as(i32, 18), futilityDepth(1658, 0));
    try std.testing.expectEqual(@as(i32, 13), futilityDepth(8195, 0));

    // The sign of either argument must not matter -- the walk keys off magnitudes.
    try std.testing.expectEqual(futilityDepth(3000, -1000), futilityDepth(-3000, 1000));

    // Walk the worst input the call site can hand over: a mated transposition value against
    // an infinite beta. Under ReleaseSafe this indexes the table and traps if the sentinel
    // ever stops covering it, which is the half the shipped build cannot check for itself.
    try std.testing.expectEqual(@as(i32, 13), futilityDepth(-value_mate, value_inf));
    try std.testing.expectEqual(@as(i32, 13), futilityDepth(value_mate, -value_inf));
}

test "fillReductions: log-scaled, index 0 untouched, monotonic from 1" {
    var r: [64]i32 = undefined;
    r[0] = -999;
    fillReductions(&r, 64);
    try std.testing.expectEqual(@as(i32, -999), r[0]); // loop starts at i=1
    try std.testing.expectEqual(@as(i32, 0), r[1]); // log(1) == 0
    try std.testing.expect(r[63] > r[2]);
    var i: usize = 2;
    while (i < 64) : (i += 1) try std.testing.expect(r[i] >= r[i - 1]);
}
