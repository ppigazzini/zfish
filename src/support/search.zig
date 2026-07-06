const std = @import("std");

const value_draw: c_int = 0;
const value_none: c_int = 32002;
const max_ply: c_int = 246;
const value_mate: c_int = 32000;
const value_mate_in_max_ply: c_int = value_mate - max_ply;
const value_mated_in_max_ply: c_int = -value_mate_in_max_ply;
const value_tb: c_int = value_mate_in_max_ply - 1;
const value_tb_win_in_max_ply: c_int = value_tb - max_ply;
const value_tb_loss_in_max_ply: c_int = -value_tb_win_in_max_ply;

fn isValid(v: c_int) bool {
    return v != value_none;
}

fn isWin(v: c_int) bool {
    return v >= value_tb_win_in_max_ply;
}

fn isLoss(v: c_int) bool {
    return v <= value_tb_loss_in_max_ply;
}

fn isMate(v: c_int) bool {
    return v >= value_mate_in_max_ply;
}

fn isMated(v: c_int) bool {
    return v <= value_mated_in_max_ply;
}

pub fn toCorrectedStaticEval(v: c_int, cv: c_int) c_int {
    const adjusted = v + @divTrunc(cv, 131072);
    return std.math.clamp(adjusted, value_tb_loss_in_max_ply + 1, value_tb_win_in_max_ply - 1);
}

pub fn valueDraw(nodes: usize) c_int {
    return value_draw - 1 + @as(c_int, @intCast(nodes & 0x2));
}

// Adjusts a mate or TB score to "plies to mate from the current position"
// before storing it in the transposition table. Standard scores are unchanged.
pub fn valueToTt(v: c_int, ply: c_int) c_int {
    if (isWin(v)) return v + ply;
    if (isLoss(v)) return v - ply;
    return v;
}

// Inverse of valueToTt(): adjusts a mate/TB score read from the transposition
// table back to plies-from-root, downgrading potentially false mate/TB scores
// related to the 50-move rule and graph-history interaction.
pub fn valueFromTt(v: c_int, ply: c_int, r50c: c_int) c_int {
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

// Step 8 child-node futility pruning. futilityMult inlines
// interpolate(min(depth,10), 1, 10, 40, 80) = 40 + 40*(d-1)/9.
pub fn futilityMargin(
    depth: c_int,
    tt_hit: bool,
    improving: bool,
    opponent_worsening: bool,
    correction_value: c_int,
) c_int {
    const d = @min(depth, 10);
    var futility_mult: c_int = 40 + @divTrunc(40 * (d - 1), 9);
    futility_mult -= 20 * @as(c_int, @intFromBool(!tt_hit));
    const imp: c_int = @intFromBool(improving);
    const opp: c_int = @intFromBool(opponent_worsening);
    const abs_corr: c_int = if (correction_value < 0) -correction_value else correction_value;
    return futility_mult * depth -
        @divTrunc((2934 * imp + 343 * opp) * futility_mult, 1024) +
        @divTrunc(abs_corr, 182069);
}

pub fn futilityReturn(beta: c_int, eval: c_int) c_int {
    return @divTrunc(716 * beta + 308 * eval, 1024);
}

// Quiet-move pruning in the move loop: continuation-history prune threshold,
// parent-node futility value, and the negative-SEE margin.
pub fn historyPruneThreshold(depth: c_int) c_int {
    return -4313 * depth;
}

pub fn quietFutilityValue(static_eval: c_int, no_best_move: bool, lmr_depth: c_int, eval_gt_alpha: bool) c_int {
    return static_eval + 40 + 138 * @as(c_int, @intFromBool(no_best_move)) +
        117 * lmr_depth + 90 * @as(c_int, @intFromBool(eval_gt_alpha));
}

pub fn quietSeeMargin(lmr_depth: c_int) c_int {
    return 25 * lmr_depth * lmr_depth;
}

// Post-search bonus formulas (ttMoveHistory updates and the prior-countermove
// fail-low bonus).
pub fn ttMoveHistoryDepthBonus(depth: c_int) c_int {
    return -442 - 108 * depth;
}

pub fn ttMoveHistoryMatchBonus(best_is_tt: bool) c_int {
    return if (best_is_tt) 792 else -779;
}

pub fn priorBonusScale(prev_stat_score: c_int, depth: c_int, prev_movecount_gt8: bool, cond_a: bool, cond_b: bool) c_int {
    var s: c_int = -245;
    s -= @divTrunc(prev_stat_score, 98);
    s += @min(59 * depth, 430);
    s += 191 * @as(c_int, @intFromBool(prev_movecount_gt8));
    s += 143 * @as(c_int, @intFromBool(cond_a));
    s += 151 * @as(c_int, @intFromBool(cond_b));
    return @max(s, 0);
}

pub fn priorScaledBonusBase(depth: c_int) c_int {
    return @min(141 * depth - 82, 1472);
}

// LMR reduction (r) adjustments before the reduced search.
pub fn lmrTtpvReduction(pv_node: bool, value_gt_alpha: bool, depth_ge: bool, cut_node: bool) c_int {
    return 2766 + @as(c_int, @intFromBool(pv_node)) * 1017 +
        @as(c_int, @intFromBool(value_gt_alpha)) * 838 +
        @as(c_int, @intFromBool(depth_ge)) * (923 + @as(c_int, @intFromBool(cut_node)) * 955);
}

pub fn lmrCorrReduction(correction_value: c_int) c_int {
    const a: c_int = if (correction_value < 0) -correction_value else correction_value;
    return @divTrunc(a, 26131);
}

pub fn lmrStatScoreReduction(stat_score: c_int) c_int {
    return @divTrunc(stat_score * 445, 4096);
}

pub fn lmrAllNodeScale(r: c_int, depth: c_int) c_int {
    return @divTrunc(r * 272, 256 * depth + 285);
}

// Singular extension margins. corrValAdj = abs(correctionValue)/194822 is
// shared by both margins.
fn corrValAdj(correction_value: c_int) c_int {
    const a: c_int = if (correction_value < 0) -correction_value else correction_value;
    return @divTrunc(a, 194822);
}

pub fn singularBeta(tt_value: c_int, ttpv_and_not_pv: bool, depth: c_int) c_int {
    return tt_value - @divTrunc((60 + 70 * @as(c_int, @intFromBool(ttpv_and_not_pv))) * depth, 59);
}

pub fn singularDoubleMargin(pv_node: bool, not_tt_capture: bool, correction_value: c_int, tt_move_history: c_int, ply_gt_root: bool) c_int {
    return -3 + 201 * @as(c_int, @intFromBool(pv_node)) - 157 * @as(c_int, @intFromBool(not_tt_capture)) -
        corrValAdj(correction_value) - @divTrunc(1081 * tt_move_history, 117824) -
        @as(c_int, @intFromBool(ply_gt_root)) * 41;
}

pub fn singularTripleMargin(pv_node: bool, not_tt_capture: bool, ttpv: bool, correction_value: c_int, ply_gt_root: bool) c_int {
    return 72 + 306 * @as(c_int, @intFromBool(pv_node)) - 188 * @as(c_int, @intFromBool(not_tt_capture)) +
        84 * @as(c_int, @intFromBool(ttpv)) - corrValAdj(correction_value) -
        @as(c_int, @intFromBool(ply_gt_root)) * 45;
}

// Capture pruning in the move loop: futility value (piece_value is the C++
// PieceValue[] lookup, passed in) and the SEE pruning margin.
pub fn captureFutilityValue(static_eval: c_int, lmr_depth: c_int, piece_value: c_int, capt_hist: c_int) c_int {
    return static_eval + 231 + 232 * lmr_depth + piece_value + @divTrunc(131 * capt_hist, 1024);
}

pub fn captureSeeMargin(depth: c_int, capt_hist: c_int) c_int {
    // upstream e4a635486: drop the max(..,0) clamp.
    return 175 * depth + @divTrunc(capt_hist * 34, 1024);
}

// Late-move-count pruning: skip quiets once moveCount reaches this limit.
pub fn moveCountLimit(depth: c_int, improving: bool) c_int {
    return @divTrunc(3 + depth * depth, 2 - @as(c_int, @intFromBool(improving)));
}

// Step 11 ProbCut beta thresholds (shallow probcut and the deep TT cutoff).
pub fn probCutBeta(beta: c_int, improving: bool) c_int {
    return beta + 214 - 59 * @as(c_int, @intFromBool(improving));
}

pub fn probCutBetaDeep(beta: c_int) c_int {
    return beta + 428;
}

// Step 9 null-move pruning: static-eval cutoff threshold, dynamic reduction R,
// and the verification-search nmpMinPly.
pub fn nullMoveThreshold(beta: c_int, depth: c_int, improving: bool) c_int {
    return beta - 14 * depth - 45 * @as(c_int, @intFromBool(improving)) + 374;
}

pub fn nullMoveReduction(depth: c_int) c_int {
    return 7 + @divTrunc(depth, 3);
}

pub fn nmpMinPly(ply: c_int, depth: c_int, r: c_int) c_int {
    return ply + @divTrunc(3 * (depth - r), 4);
}

// Step 7 razoring threshold subtracted from alpha (search()).
pub fn razorMargin(depth: c_int) c_int {
    return 465 + 300 * depth * depth;
}

// Qsearch beta-trend blends: when a non-decisive bestValue clears beta it is
// pulled partway toward beta. Step 4 stand-pat uses 467/557; the pre-TT-store
// fail-high path uses 481/543. Both divide by 1024 with toward-zero truncation.
pub fn qsearchStandPatBlend(best_value: c_int, beta: c_int) c_int {
    return @divTrunc(467 * best_value + 557 * beta, 1024);
}

pub fn qsearchFailHighBlend(best_value: c_int, beta: c_int) c_int {
    return @divTrunc(481 * best_value + 543 * beta, 1024);
}

// Static-eval-difference quiet ordering (search(), after the moves_loop check
// guard): clamp the negated sum of the previous and current static evals into
// [-183, 180] and bias by 62. The caller scales it (*10, *13) into history.
pub fn evalDiff(prev_static_eval: c_int, static_eval: c_int) c_int {
    return @max(@as(c_int, -183), @min(@as(c_int, 180), -(prev_static_eval + static_eval))) + 62;
}

// Qsearch futility base = static eval plus a fixed margin (search.cpp qsearch
// step 4). The move loop later adds the captured piece value to this base.
pub fn qsearchFutilityBase(static_eval: c_int) c_int {
    return static_eval + 335;
}

// Prior-countermove fail-low bonus scalings (search() POST_BONUS block): the
// scaledBonus is fanned out into the continuation, main, and pawn history
// tables with distinct tuned divisors, each truncated toward zero.
pub fn priorConthistScale(scaled_bonus: c_int) c_int {
    return @divTrunc(scaled_bonus * 236, 16384);
}

pub fn priorMainhistScale(scaled_bonus: c_int) c_int {
    return @divTrunc(scaled_bonus * 234, 32768);
}

pub fn priorPawnhistScale(scaled_bonus: c_int) c_int {
    return @divTrunc(scaled_bonus * 322, 8192);
}

// Step 17 LMR stat-score assembly (search()). The caller reads the relevant
// history-table entries and passes their values; Zig owns the tuned weighting.
// Capture: 809*pieceValue/128 plus capture history. Quiet: 2*main plus the two
// continuation-history entries.
pub fn captureStatScore(piece_value: c_int, capture_hist: c_int) c_int {
    return @divTrunc(809 * piece_value, 128) + capture_hist;
}

pub fn quietStatScore(main_hist: c_int, cont0: c_int, cont1: c_int) c_int {
    return 2 * main_hist + cont0 + cont1;
}

// End-of-search correction-history bonus (search()): scale the static-eval
// error by depth and a best-move-dependent weight (12 with a best move, 18
// without), clamp into +/- CORRECTION_HISTORY_LIMIT/4 (=256), then apply the
// final 1114/1024 scale passed to update_correction_history.
pub fn correctionHistoryBonus(eval_delta: c_int, depth: c_int, has_best_move: bool) c_int {
    const w: c_int = if (has_best_move) 12 else 18;
    const raw = @divTrunc(eval_delta * depth * w, 128);
    const clamped = @max(@as(c_int, -256), @min(@as(c_int, 256), raw));
    return @divTrunc(1114 * clamped, 1024);
}

// Aspiration-window sizing in iterative_deepening(). The starting half-width
// mixes a base, a per-thread stagger, and the root move's mean-squared score;
// on each fail high/low it grows by 44/128.
pub fn aspirationInitialDelta(thread_idx: usize, mean_squared_score: c_int) c_int {
    const tmod: c_int = @intCast(thread_idx % 8);
    const abs_mss = if (mean_squared_score < 0) -mean_squared_score else mean_squared_score;
    return 5 + tmod + @divTrunc(abs_mss, 10588);
}

pub fn aspirationDeltaGrow(delta: c_int) c_int {
    return delta + @divTrunc(44 * delta, 128);
}

// Eval optimism from the root move's average score (iterative_deepening()):
// a saturating 137*avg/(|avg|+81). The caller mirrors it for the opponent.
pub fn optimism(avg: c_int) c_int {
    const abs_avg = if (avg < 0) -avg else avg;
    return @divTrunc(137 * avg, abs_avg + 81);
}

// Quiet-history bonus scalings (update_quiet_histories). Each is bonus*N/1024
// with toward-zero division; the pawn-history scale picks its weight by sign.
pub fn quietLowPlyScale(bonus: c_int) c_int {
    return @divTrunc(bonus * 663, 1024);
}

pub fn quietContScale(bonus: c_int) c_int {
    return @divTrunc(bonus * 820, 1024);
}

pub fn quietPawnScale(bonus: c_int) c_int {
    const weight: c_int = if (bonus > -7) 1038 else 525;
    return @divTrunc(bonus * weight, 1024);
}

// Continuation-history positive-consistency multipliers, indexed by the
// running positiveCount in update_continuation_histories.
const cmhc_multipliers = [_]c_int{ 96, 113, 101, 105, 127, 121, 126 };

// Per-entry continuation-history update delta. The (i, weight) pairs and the
// positiveCount accumulation stay C++-side (they drive Stack indexing); this
// owns the multiplier table and the bonus*weight*multiplier/131072 formula.
// bonus*weight*multiplier stays within i32 for the bonus magnitudes search
// produces.
pub fn conthistDelta(bonus: c_int, weight: c_int, positive_count: c_int, i: c_int) c_int {
    const multiplier = cmhc_multipliers[@intCast(positive_count)];
    return @divTrunc(bonus * weight * multiplier, 131072) +
        71 * @as(c_int, @intFromBool(i < 2));
}

// Weighted correction-history blend (correction_value). Inputs are the raw
// correction entries read C++-side; only the magic weights live here. All
// terms stay well within i32 (entries clamped to +/-1024).
pub fn correctionValue(
    pcv: c_int,
    micv: c_int,
    wnpcv: c_int,
    bnpcv: c_int,
    cch2: c_int,
    cch4: c_int,
    m_ok: bool,
) c_int {
    const cntcv: c_int = if (m_ok) 8363 * (cch2 + cch4) else 64549;
    return 13345 * pcv + 9280 * micv + 11840 * (wnpcv + bnpcv) + cntcv;
}

// Base stat bonus/malus formulas applied at the end of search() when a
// bestMove is found (update_all_stats).
pub fn statBonus(depth: c_int, is_tt_move: bool, prev_stat_score: c_int) c_int {
    return @min(134 * depth - 79, 1572) +
        382 * @as(c_int, @intFromBool(is_tt_move)) +
        @divTrunc(prev_stat_score, 30);
}

pub fn statMalus(depth: c_int) c_int {
    return @min(1005 * depth - 205, 2218);
}

// Populate the reductions[] lookup table: reductions[i] = int(2834/128.0 * ln i)
// for i in [1, count). Index 0 is left untouched, matching upstream clear().
pub fn fillReductions(reductions_ptr: [*]c_int, count: usize) void {
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const logv = @log(@as(f64, @floatFromInt(i)));
        reductions_ptr[i] = @intFromFloat(2834.0 / 128.0 * logv);
    }
}

pub fn reduction(
    reductions_ptr: [*]const c_int,
    depth: c_int,
    move_number: c_int,
    delta: c_int,
    root_delta: c_int,
    improving: bool,
) c_int {
    const depth_index: usize = @intCast(depth);
    const move_index: usize = @intCast(move_number);
    const reduction_scale = reductions_ptr[depth_index] * reductions_ptr[move_index];
    return reduction_scale - @divTrunc(delta * 617, root_delta) + (if (!improving) @divTrunc(reduction_scale * 194, 512) else 0) + 1027;
}
