// Own the history and correction-table update formulas.
//
// Split out of search.zig, which the god-file gate put over its line when the mate-finding
// futility LUT landed. The seam is what a formula is FOR: search.zig keeps the margins a
// node prunes and reduces by, this file keeps the numbers written back to the tables
// afterwards -- the stat bonus/malus and their per-table scales, the prior-countermove
// fan-out, the LMR stat-score weighting, and the correction-history bonuses with the limit
// they are all a quarter of.
//
// std-only and imported BY PATH from search.zig alone (a file belongs to exactly one Zig
// module), which re-exports every declaration here, so the module graph and every caller
// are unchanged.

const std = @import("std");

// Compute the post-search bonus formulas (ttMoveHistory updates and the prior-countermove
// fail-low bonus).
pub fn ttMoveHistoryDepthBonus(depth: i32) i32 {
    return -421 - 110 * depth;
}

pub fn ttMoveHistoryMatchBonus(best_is_tt: bool) i32 {
    return if (best_is_tt) 918 else -747;
}

pub fn priorBonusScale(prev_stat_score: i32, depth: i32, prev_movecount_gt9: bool, cond_a: bool, cond_b: bool) i32 {
    var s: i32 = -241;
    s -= @divTrunc(prev_stat_score, 98);
    s += @min(59 * depth, 420);
    s += 186 * @as(i32, @intFromBool(prev_movecount_gt9));
    s += 142 * @as(i32, @intFromBool(cond_a));
    s += 159 * @as(i32, @intFromBool(cond_b));
    return @max(s, 0);
}

pub fn priorScaledBonusBase(depth: i32) i32 {
    return @min(150 * depth - 85, 1337);
}

// Scale the prior-countermove fail-low bonus (search() POST_BONUS block): fan the
// scaledBonus out into the continuation, main, and pawn history
// tables with distinct tuned divisors, each truncated toward zero.
pub fn priorConthistScale(scaled_bonus: i32) i32 {
    return @divTrunc(scaled_bonus * 263, 16384);
}

pub fn priorMainhistScale(scaled_bonus: i32) i32 {
    return @divTrunc(scaled_bonus * 215, 32768);
}

pub fn priorPawnhistScale(scaled_bonus: i32) i32 {
    return @divTrunc(scaled_bonus * 324, 8192);
}

// Assemble the Step 17 LMR stat-score (search()). The caller reads the relevant
// history-table entries and passes their values; this owns the tuned weighting.
// Capture: 873*pieceValue/128 plus capture history. Quiet: a weighted sum of main and the
// two continuation-history entries, scaled by 1024.
pub fn captureStatScore(piece_value: i32, capture_hist: i32) i32 {
    return @divTrunc(873 * piece_value, 128) + capture_hist;
}

pub fn quietStatScore(main_hist: i32, cont0: i32, cont1: i32) i32 {
    return @divTrunc(2252 * main_hist + 1126 * cont0 + 1093 * cont1, 1024);
}

// Bound every correction-history entry (upstream's CORRECTION_HISTORY_LIMIT). It lives
// here, in the std-only formula leaf, because both the writers in history.zig and the
// bonus clamps below have to agree on it: every bonus is clamped to a QUARTER of it, and
// a limit retuned in one place while the clamps kept a hardcoded 256 would silently stop
// being a quarter of anything.
pub const correction_history_limit: i32 = 1024;
const correction_bonus_clamp: i32 = @divTrunc(correction_history_limit, 4);

// Compute the end-of-search correction-history bonus (search()): scale the static-eval
// error by depth and a best-move-dependent weight (12 with a best move, 18
// without), clamp into +/- CORRECTION_HISTORY_LIMIT/4, then apply the
// final 1061/1024 scale passed to update_correction_history.
pub fn correctionHistoryBonus(eval_delta: i32, depth: i32, has_best_move: bool) i32 {
    const w: i32 = if (has_best_move) 12 else 18;
    const raw = @divTrunc(eval_delta * depth * w, 128);
    const clamped = @max(-correction_bonus_clamp, @min(correction_bonus_clamp, raw));
    return @divTrunc(1061 * clamped, 1024);
}

// Compute the multi-cut correction-history bonus (Step 15): when the singular
// probe itself fails high above beta it has proven the static eval too low, so
// nudge the correction tables by the scaled error. Clamp into
// +/- CORRECTION_HISTORY_LIMIT/4 like every other correction bonus.
pub fn multiCutCorrectionBonus(eval_delta: i32, singular_depth: i32) i32 {
    const raw = @divTrunc(eval_delta * singular_depth * 177, 1024);
    return @max(-correction_bonus_clamp, @min(correction_bonus_clamp, raw));
}

// Scale the quiet-history bonus (update_quiet_histories). Each is bonus*N/1024
// with toward-zero division; the pawn-history scale picks its weight by whether bonus > -4.
pub fn quietLowPlyScale(bonus: i32) i32 {
    return @divTrunc(bonus * 712, 1024);
}

pub fn quietContScale(bonus: i32) i32 {
    return @divTrunc(bonus * 750, 1024);
}

pub fn quietPawnScale(bonus: i32) i32 {
    const weight: i32 = if (bonus > -4) 1104 else 459;
    return @divTrunc(bonus * weight, 1024);
}

// Index the continuation-history positive-consistency multipliers by the
// running positiveCount in update_continuation_histories.
const cmhc_multipliers = [_]i32{ 94, 103, 110, 106, 119, 126, 121 };

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
        73 * @as(i32, @intFromBool(i < 2));
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
    const cntcv: i32 = if (m_ok) 8761 * (cch2 + cch4) else 64049;
    return 15341 * pcv + 10569 * micv + 12906 * (wnpcv + bnpcv) + cntcv;
}

// Compute the base stat bonus/malus formulas applied at the end of search() when a
// bestMove is found (update_all_stats).
pub fn statBonus(depth: i32, is_tt_move: bool, prev_stat_score: i32) i32 {
    return @min(133 * depth - 81, 1487) +
        364 * @as(i32, @intFromBool(is_tt_move)) +
        @divTrunc(prev_stat_score, 28);
}

pub fn statMalus(depth: i32) i32 {
    return @min(968 * depth - 235, 2244);
}

// --- tests --------------------------------------------------------------
test "multiCutCorrectionBonus: clamps at a quarter of the correction-history limit" {
    const quarter = @divTrunc(correction_history_limit, 4);

    try std.testing.expectEqual(@as(i32, 0), multiCutCorrectionBonus(0, 8)); // no delta, no bonus

    // Pin the 177 weight itself. Pick delta*singular_depth == 1024 so the /1024 divides
    // out and the answer IS the weight -- at a smaller product the truncation swallows a
    // one-off change to it (64*4*177/1024 and 64*4*178/1024 are both 44).
    try std.testing.expectEqual(@as(i32, 177), multiCutCorrectionBonus(64, 16));

    try std.testing.expectEqual(quarter, multiCutCorrectionBonus(30000, 60));
    try std.testing.expectEqual(-quarter, multiCutCorrectionBonus(-30000, 60));
}

test "correction bonuses track the limit they are a quarter of" {
    // Both clamps derive from correction_history_limit rather than repeating 256, so a
    // retuned limit moves them together. Assert the relationship, not the number.
    //
    // Stay inside the domain the callers can actually reach: both bodies multiply three
    // i32 terms before dividing, so a delta beyond a non-decisive score (~32k) times a
    // plausible depth overflows i32 and the clamp reports the WRONG sign. That is a
    // property of the formula, not of these inputs -- the same shape as the conthistDelta
    // overflow ReleaseSafe caught. Callers bound the delta: the multi-cut site is guarded
    // by `!qIsDecisive(value)`, and the end-of-search site by a real eval difference.
    const quarter = @divTrunc(correction_history_limit, 4);
    try std.testing.expectEqual(quarter, multiCutCorrectionBonus(30000, 60));
    // correctionHistoryBonus clamps to the same quarter, then applies its 1061/1024 scale.
    try std.testing.expectEqual(@divTrunc(1061 * quarter, 1024), correctionHistoryBonus(30000, 64, true));
}
