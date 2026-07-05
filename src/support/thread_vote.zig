// Lazy-SMP best-thread vote (M16.7, relocated from thread.zig).
//
// A leaf module (graph_layout only): picks the vote-winning thread's worker from the
// pool's per-thread root-move summaries. Both thread.zig and the search driver
// (position.zig) select the best thread, and position cannot import thread (thread
// imports position), so the pure graph-read + integer-vote logic lives here.

const graph_layout = @import("graph_layout");

const value_none: c_int = 32002;
const value_infinite: c_int = 32001;
const value_tb_win_in_max_ply: c_int = 31507;
const value_tb_loss_in_max_ply: c_int = -31507;
const max_thread_summaries: usize = 1024;

pub const ThreadSummary = struct {
    pv0_raw: u16,
    score_is_bound: u8,
    pv_has_more_than_two: u8,
    score: c_int,
    root_depth: c_int,
};

fn fillThreadSummary(thread: *anyopaque, out: *ThreadSummary) void {
    const w = graph_layout.Worker.fromThread(thread) orelse return;
    const rmv = w.rootMovesFirst();
    out.pv0_raw = rmv.pv.moves[0];
    out.score_is_bound = @intFromBool(rmv.score_lowerbound != 0 or rmv.score_upperbound != 0);
    out.pv_has_more_than_two = @intFromBool(rmv.pv.length > 2);
    out.score = rmv.score;
    out.root_depth = w.rootDepth();
}

fn voteForMove(summaries: [*]const ThreadSummary, count: usize, move_raw: u16, min_score: c_int) c_int {
    var vote: c_int = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (summaries[index].pv0_raw == move_raw)
            vote += threadVotingValue(summaries[index], min_score);
    }
    return vote;
}

fn threadVotingValue(summary: ThreadSummary, min_score: c_int) c_int {
    return (summary.score - min_score + 14) * summary.root_depth;
}

fn isWin(score: c_int) bool {
    return score >= value_tb_win_in_max_ply;
}
fn isLoss(score: c_int) bool {
    return score <= value_tb_loss_in_max_ply;
}
fn isDecisive(score: c_int) bool {
    return isWin(score) or isLoss(score);
}
fn isDecisiveBest(summary: ThreadSummary) bool {
    return summary.score != -value_infinite and isDecisive(summary.score) and summary.score_is_bound == 0;
}
fn absInt(value: c_int) c_int {
    return if (value < 0) -value else value;
}

fn pickBestThread(summaries: [*]const ThreadSummary, count: usize) usize {
    var best_index: usize = 0;
    var min_score: c_int = value_none;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (summaries[index].score < min_score)
            min_score = summaries[index].score;
    }

    index = 0;
    while (index < count) : (index += 1) {
        const best = summaries[best_index];
        const current = summaries[index];
        const best_vote = voteForMove(summaries, count, best.pv0_raw, min_score);
        const current_vote = voteForMove(summaries, count, current.pv0_raw, min_score);
        const best_decisive = isDecisiveBest(best);
        const current_decisive = isDecisiveBest(current);
        const better_voting_value =
            threadVotingValue(current, min_score) * @as(c_int, current.pv_has_more_than_two) > threadVotingValue(best, min_score) * @as(c_int, best.pv_has_more_than_two);

        if (best_decisive) {
            if (current_decisive and absInt(current.score) > absInt(best.score)) {
                best_index = index;
            }
        } else if (current_decisive or
            (!isLoss(current.score) and
                (current_vote > best_vote or (current_vote == best_vote and better_voting_value))))
        {
            best_index = index;
        }
    }

    return best_index;
}

// Index of the vote-winning thread within the pool.
pub fn bestThreadIndex(pool: *anyopaque) usize {
    const thread_count = graph_layout.ThreadPool.fromPtr(@constCast(pool)).numThreads();
    if (thread_count == 0) return 0;
    if (thread_count > max_thread_summaries) @panic("thread summary buffer too small");

    var summaries: [max_thread_summaries]ThreadSummary = undefined;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        fillThreadSummary(graph_layout.ThreadPool.fromPtr(@constCast(pool)).threadAtPtr(index), &summaries[index]);
    }
    return pickBestThread(&summaries, thread_count);
}

// Worker pointer (as usize) of the vote-winning thread -- the value the search driver
// picks as `bestThread` when choosing the move to report.
pub fn bestThreadWorker(pool: *anyopaque) usize {
    const idx = bestThreadIndex(pool);
    const thread = graph_layout.ThreadPool.fromAddr(@intFromPtr(pool)).threadAt(idx);
    return graph_layout.Thread.fromAddr(thread).worker;
}
