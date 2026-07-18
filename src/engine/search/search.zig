const std = @import("std");

const value_draw: i32 = 0;
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

// Prune child-node futility (Step 8): futilityMult = min(40 + depth*4, 80).
pub fn futilityMargin(
    depth: i32,
    tt_hit: bool,
    improving: bool,
    opponent_worsening: bool,
    correction_value: i32,
) i32 {
    var futility_mult: i32 = @min(40 + depth * 4, 80);
    futility_mult -= 20 * @as(i32, @intFromBool(!tt_hit));
    const imp: i32 = @intFromBool(improving);
    const opp: i32 = @intFromBool(opponent_worsening);
    const abs_corr: i32 = if (correction_value < 0) -correction_value else correction_value;
    return futility_mult * depth -
        @divTrunc((2934 * imp + 343 * opp) * futility_mult, 1024) +
        @divTrunc(abs_corr, 182069);
}

pub fn futilityReturn(beta: i32, eval: i32) i32 {
    return @divTrunc(716 * beta + 308 * eval, 1024);
}

// Prune quiet moves in the move loop: continuation-history prune threshold,
// parent-node futility value, and the negative-SEE margin.
pub fn historyPruneThreshold(depth: i32) i32 {
    return -4313 * depth;
}

pub fn quietFutilityValue(static_eval: i32, no_best_move: bool, lmr_depth: i32, eval_gt_alpha: bool) i32 {
    return static_eval + 40 + 138 * @as(i32, @intFromBool(no_best_move)) +
        117 * lmr_depth + 90 * @as(i32, @intFromBool(eval_gt_alpha));
}

pub fn quietSeeMargin(lmr_depth: i32) i32 {
    return 25 * lmr_depth * lmr_depth;
}

// Compute the post-search bonus formulas (ttMoveHistory updates and the prior-countermove
// fail-low bonus).
pub fn ttMoveHistoryDepthBonus(depth: i32) i32 {
    return -442 - 108 * depth;
}

pub fn ttMoveHistoryMatchBonus(best_is_tt: bool) i32 {
    return if (best_is_tt) 792 else -779;
}

pub fn priorBonusScale(prev_stat_score: i32, depth: i32, prev_movecount_gt8: bool, cond_a: bool, cond_b: bool) i32 {
    var s: i32 = -245;
    s -= @divTrunc(prev_stat_score, 98);
    s += @min(59 * depth, 430);
    s += 191 * @as(i32, @intFromBool(prev_movecount_gt8));
    s += 143 * @as(i32, @intFromBool(cond_a));
    s += 151 * @as(i32, @intFromBool(cond_b));
    return @max(s, 0);
}

pub fn priorScaledBonusBase(depth: i32) i32 {
    return @min(141 * depth - 82, 1472);
}

// Adjust the LMR reduction (r) before the reduced search.
pub fn lmrTtpvReduction(pv_node: bool, value_gt_alpha: bool, depth_ge: bool, cut_node: bool) i32 {
    return 2766 + @as(i32, @intFromBool(pv_node)) * 1017 +
        @as(i32, @intFromBool(value_gt_alpha)) * 838 +
        @as(i32, @intFromBool(depth_ge)) * (923 + @as(i32, @intFromBool(cut_node)) * 955);
}

pub fn lmrCorrReduction(correction_value: i32) i32 {
    const a: i32 = if (correction_value < 0) -correction_value else correction_value;
    return @divTrunc(a, 26131);
}

pub fn lmrStatScoreReduction(stat_score: i32) i32 {
    return @divTrunc(stat_score * 445, 4096);
}

pub fn lmrAllNodeScale(r: i32, depth: i32) i32 {
    return @divTrunc(r * 272, 256 * depth + 285);
}

// Compute the singular extension margins. corrValAdj = abs(correctionValue)/194822 is
// shared by both margins.
fn corrValAdj(correction_value: i32) i32 {
    const a: i32 = if (correction_value < 0) -correction_value else correction_value;
    return @divTrunc(a, 194822);
}

pub fn singularBeta(tt_value: i32, ttpv_and_not_pv: bool, depth: i32) i32 {
    return tt_value - @divTrunc((60 + 70 * @as(i32, @intFromBool(ttpv_and_not_pv))) * depth, 59);
}

pub fn singularDoubleMargin(pv_node: bool, not_tt_capture: bool, correction_value: i32, tt_move_history: i32, ply_gt_root: bool) i32 {
    return -3 + 201 * @as(i32, @intFromBool(pv_node)) - 157 * @as(i32, @intFromBool(not_tt_capture)) -
        corrValAdj(correction_value) - @divTrunc(1081 * tt_move_history, 117824) -
        @as(i32, @intFromBool(ply_gt_root)) * 41;
}

pub fn singularTripleMargin(pv_node: bool, not_tt_capture: bool, ttpv: bool, correction_value: i32, ply_gt_root: bool) i32 {
    return 72 + 306 * @as(i32, @intFromBool(pv_node)) - 188 * @as(i32, @intFromBool(not_tt_capture)) +
        84 * @as(i32, @intFromBool(ttpv)) - corrValAdj(correction_value) -
        @as(i32, @intFromBool(ply_gt_root)) * 45;
}

// Prune captures in the move loop: futility value (piece_value is the
// piece-value lookup, passed in) and the SEE pruning margin.
pub fn captureFutilityValue(static_eval: i32, lmr_depth: i32, piece_value: i32, capt_hist: i32) i32 {
    return static_eval + 231 + 232 * lmr_depth + piece_value + @divTrunc(131 * capt_hist, 1024);
}

pub fn captureSeeMargin(depth: i32, capt_hist: i32) i32 {
    // upstream e4a635486: drop the max(..,0) clamp.
    return 175 * depth + @divTrunc(capt_hist * 34, 1024);
}

// Prune by late move count: skip quiets once moveCount reaches this limit.
pub fn moveCountLimit(depth: i32, improving: bool) i32 {
    return @divTrunc(3 + depth * depth, 2 - @as(i32, @intFromBool(improving)));
}

// Compute the Step 11 ProbCut beta thresholds (shallow probcut and the deep TT cutoff).
pub fn probCutBeta(beta: i32, improving: bool) i32 {
    return beta + 214 - 59 * @as(i32, @intFromBool(improving));
}

pub fn probCutBetaDeep(beta: i32) i32 {
    return beta + 428;
}

// Prune with the null move (Step 9): static-eval cutoff threshold, dynamic reduction R,
// and the verification-search nmpMinPly.
pub fn nullMoveThreshold(beta: i32, depth: i32, improving: bool) i32 {
    return beta - 14 * depth - 45 * @as(i32, @intFromBool(improving)) + 374;
}

pub fn nullMoveReduction(depth: i32) i32 {
    return 7 + @divTrunc(depth, 3);
}

pub fn nmpMinPly(ply: i32, depth: i32, r: i32) i32 {
    return ply + @divTrunc(3 * (depth - r), 4);
}

// Compute the Step 7 razoring threshold subtracted from alpha (search()).
pub fn razorMargin(depth: i32) i32 {
    return 465 + 300 * depth * depth;
}

// Blend the qsearch beta-trend: when a non-decisive bestValue clears beta it is
// pulled partway toward beta. Step 4 stand-pat uses 467/557; the pre-TT-store
// fail-high path uses 481/543. Both divide by 1024 with toward-zero truncation.
pub fn qsearchStandPatBlend(best_value: i32, beta: i32) i32 {
    return @divTrunc(467 * best_value + 557 * beta, 1024);
}

pub fn qsearchFailHighBlend(best_value: i32, beta: i32) i32 {
    return @divTrunc(481 * best_value + 543 * beta, 1024);
}

// Order quiets by static-eval difference (search(), after the moves_loop check
// guard): clamp the negated sum of the previous and current static evals into
// [-183, 180] and bias by 62. The caller scales it (*10, *13) into history.
pub fn evalDiff(prev_static_eval: i32, static_eval: i32) i32 {
    return @max(@as(i32, -183), @min(@as(i32, 180), -(prev_static_eval + static_eval))) + 62;
}

// Compute the qsearch futility base = static eval plus a fixed margin. The move loop later
// adds the captured piece value to this base.
pub fn qsearchFutilityBase(static_eval: i32) i32 {
    return static_eval + 335;
}

// Scale the prior-countermove fail-low bonus (search() POST_BONUS block): fan the
// scaledBonus out into the continuation, main, and pawn history
// tables with distinct tuned divisors, each truncated toward zero.
pub fn priorConthistScale(scaled_bonus: i32) i32 {
    return @divTrunc(scaled_bonus * 236, 16384);
}

pub fn priorMainhistScale(scaled_bonus: i32) i32 {
    return @divTrunc(scaled_bonus * 234, 32768);
}

pub fn priorPawnhistScale(scaled_bonus: i32) i32 {
    return @divTrunc(scaled_bonus * 322, 8192);
}

// Assemble the Step 17 LMR stat-score (search()). The caller reads the relevant
// history-table entries and passes their values; this owns the tuned weighting.
// Capture: 809*pieceValue/128 plus capture history. Quiet: 2*main plus the two
// continuation-history entries.
pub fn captureStatScore(piece_value: i32, capture_hist: i32) i32 {
    return @divTrunc(809 * piece_value, 128) + capture_hist;
}

pub fn quietStatScore(main_hist: i32, cont0: i32, cont1: i32) i32 {
    return 2 * main_hist + cont0 + cont1;
}

// Compute the end-of-search correction-history bonus (search()): scale the static-eval
// error by depth and a best-move-dependent weight (12 with a best move, 18
// without), clamp into +/- CORRECTION_HISTORY_LIMIT/4 (=256), then apply the
// final 1114/1024 scale passed to update_correction_history.
pub fn correctionHistoryBonus(eval_delta: i32, depth: i32, has_best_move: bool) i32 {
    const w: i32 = if (has_best_move) 12 else 18;
    const raw = @divTrunc(eval_delta * depth * w, 128);
    const clamped = @max(@as(i32, -256), @min(@as(i32, 256), raw));
    return @divTrunc(1114 * clamped, 1024);
}

// Size the aspiration window in iterative_deepening(). The starting half-width
// mixes a base, a per-thread stagger, and the root move's mean-squared score;
// on each fail high/low it grows by 44/128.
pub fn aspirationInitialDelta(thread_idx: usize, mean_squared_score: i32) i32 {
    const tmod: i32 = @intCast(thread_idx % 8);
    const abs_mss = if (mean_squared_score < 0) -mean_squared_score else mean_squared_score;
    return 5 + tmod + @divTrunc(abs_mss, 10588);
}

pub fn aspirationDeltaGrow(delta: i32) i32 {
    return delta + @divTrunc(44 * delta, 128);
}

// Compute eval optimism from the root move's average score (iterative_deepening()):
// a saturating 137*avg/(|avg|+81). The caller mirrors it for the opponent.
pub fn optimism(avg: i32) i32 {
    const abs_avg = if (avg < 0) -avg else avg;
    return @divTrunc(137 * avg, abs_avg + 81);
}

// Scale the quiet-history bonus (update_quiet_histories). Each is bonus*N/1024
// with toward-zero division; the pawn-history scale picks its weight by sign.
pub fn quietLowPlyScale(bonus: i32) i32 {
    return @divTrunc(bonus * 663, 1024);
}

pub fn quietContScale(bonus: i32) i32 {
    return @divTrunc(bonus * 820, 1024);
}

pub fn quietPawnScale(bonus: i32) i32 {
    const weight: i32 = if (bonus > -7) 1038 else 525;
    return @divTrunc(bonus * weight, 1024);
}

// Index the continuation-history positive-consistency multipliers by the
// running positiveCount in update_continuation_histories.
const cmhc_multipliers = [_]i32{ 96, 113, 101, 105, 127, 121, 126 };

// Compute the per-entry continuation-history update delta: own the multiplier table
// and the bonus*weight*multiplier/131072 formula. bonus*weight*multiplier
// stays within i32 for the bonus magnitudes search produces.
pub fn conthistDelta(bonus: i32, weight: i32, positive_count: i32, i: i32) i32 {
    const multiplier = cmhc_multipliers[@intCast(positive_count)];
    // Upstream (search.cpp: `bonus * weight * multiplier / 131072`) computes this in `int`,
    // so the 3-way product overflows i32 for large bonuses and WRAPS (2's complement on
    // x86 -- UB in C++ but relied upon). Match it with `*%` so the wrap is bit-identical
    // (the shipped ReleaseFast build already wrapped here; this only stops ReleaseSafe's
    // overflow trap from aborting on deep searches -- the value is unchanged).
    return @divTrunc(bonus *% weight *% multiplier, 131072) +
        71 * @as(i32, @intFromBool(i < 2));
}

// Blend the weighted correction history (correction_value). Inputs are the raw
// correction entries; only the magic weights live here. All terms stay well
// within i32 (entries clamped to +/-1024).
pub fn correctionValue(
    pcv: i32,
    micv: i32,
    wnpcv: i32,
    bnpcv: i32,
    cch2: i32,
    cch4: i32,
    m_ok: bool,
) i32 {
    const cntcv: i32 = if (m_ok) 8363 * (cch2 + cch4) else 64549;
    return 13345 * pcv + 9280 * micv + 11840 * (wnpcv + bnpcv) + cntcv;
}

// Compute the base stat bonus/malus formulas applied at the end of search() when a
// bestMove is found (update_all_stats).
pub fn statBonus(depth: i32, is_tt_move: bool, prev_stat_score: i32) i32 {
    return @min(134 * depth - 79, 1572) +
        382 * @as(i32, @intFromBool(is_tt_move)) +
        @divTrunc(prev_stat_score, 30);
}

pub fn statMalus(depth: i32) i32 {
    return @min(1005 * depth - 205, 2218);
}

// Populate the reductions[] lookup table: reductions[i] = int(2834/128.0 * ln i)
// for i in [1, count). Index 0 is left untouched, matching upstream clear().
pub fn fillReductions(reductions_ptr: [*]i32, count: usize) void {
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const logv = @log(@as(f64, @floatFromInt(i)));
        reductions_ptr[i] = @intFromFloat(2834.0 / 128.0 * logv);
    }
}

pub fn reduction(
    reductions_ptr: [*]const i32,
    depth: i32,
    move_number: i32,
    delta: i32,
    root_delta: i32,
    improving: bool,
) i32 {
    const depth_index: usize = @intCast(depth);
    const move_index: usize = @intCast(move_number);
    const reduction_scale = reductions_ptr[depth_index] * reductions_ptr[move_index];
    return reduction_scale - @divTrunc(delta * 617, root_delta) + (if (!improving) @divTrunc(reduction_scale * 194, 512) else 0) + 1027;
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
