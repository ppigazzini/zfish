// Vote for the Lazy-SMP best thread.
//
// Pick the vote-winning thread's worker from the pool's per-thread root-move summaries;
// a leaf module (worker_layout only). Both thread.zig and the search driver (position.zig)
// select the best thread, and position cannot import thread (thread imports position),
// so keep the pure graph-read + integer-vote logic here.

const worker_layout = @import("worker_layout");

const value_none: i32 = 32002;
const value_infinite: i32 = 32001;
const value_tb_win_in_max_ply: i32 = 31507;
const value_tb_loss_in_max_ply: i32 = -31507;
const max_thread_summaries: usize = 1024;

pub const ThreadSummary = struct {
    pv0_raw: u16,
    score_is_bound: u8,
    pv_has_more_than_two: u8,
    score: i32,
    root_depth: i32,
};

// Write a neutral record for a thread with no Worker rather than leaving the caller's slot
// untouched: the slot would stay `undefined` and pickBestThread reads .score/.root_depth out
// of it, making best-thread selection depend on stack garbage.
fn fillThreadSummary(thread: *worker_layout.Thread, out: *ThreadSummary) void {
    const w = worker_layout.Worker.fromThread(thread) orelse {
        out.* = .{
            .pv0_raw = 0,
            .score_is_bound = 1,
            .pv_has_more_than_two = 0,
            .score = value_none,
            .root_depth = 0,
        };
        return;
    };
    const rmv = w.rootMovesFirst();
    out.pv0_raw = rmv.pv.moves[0];
    out.score_is_bound = @intFromBool(rmv.score_lowerbound or rmv.score_upperbound);
    out.pv_has_more_than_two = @intFromBool(rmv.pv.length > 2);
    out.score = rmv.score;
    out.root_depth = w.rootDepth();
}

fn voteForMove(summaries: []const ThreadSummary, move_raw: u16, min_score: i32) i32 {
    var vote: i32 = 0;
    var index: usize = 0;
    while (index < summaries.len) : (index += 1) {
        if (summaries[index].pv0_raw == move_raw)
            vote += threadVotingValue(summaries[index], min_score);
    }
    return vote;
}

fn threadVotingValue(summary: ThreadSummary, min_score: i32) i32 {
    return (summary.score - min_score + 14) * summary.root_depth;
}

fn isWin(score: i32) bool {
    return score >= value_tb_win_in_max_ply;
}
fn isLoss(score: i32) bool {
    return score <= value_tb_loss_in_max_ply;
}
fn isDecisive(score: i32) bool {
    return isWin(score) or isLoss(score);
}
fn isDecisiveBest(summary: ThreadSummary) bool {
    return summary.score != -value_infinite and isDecisive(summary.score) and summary.score_is_bound == 0;
}
fn absInt(value: i32) i32 {
    return if (value < 0) -value else value;
}

fn pickBestThread(summaries: []const ThreadSummary) usize {
    var best_index: usize = 0;
    var min_score: i32 = value_none;

    var index: usize = 0;
    while (index < summaries.len) : (index += 1) {
        if (summaries[index].score < min_score)
            min_score = summaries[index].score;
    }

    index = 0;
    while (index < summaries.len) : (index += 1) {
        const best = summaries[best_index];
        const current = summaries[index];
        const best_vote = voteForMove(summaries, best.pv0_raw, min_score);
        const current_vote = voteForMove(summaries, current.pv0_raw, min_score);
        const best_decisive = isDecisiveBest(best);
        const current_decisive = isDecisiveBest(current);
        const better_voting_value =
            threadVotingValue(current, min_score) * @as(i32, current.pv_has_more_than_two) > threadVotingValue(best, min_score) * @as(i32, best.pv_has_more_than_two);

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

// Return the index of the vote-winning thread within the pool.
pub fn bestThreadIndex(pool: *worker_layout.ThreadPool) usize {
    const thread_count = pool.numThreads();
    if (thread_count == 0) return 0;

    // Vote over the threads that fit the fixed buffer. The Threads option advertises
    // @max(1024, 4 * hardwareConcurrency()), so a host with more than 256 logical CPUs can
    // legally exceed this bound; aborting mid-search on a value the engine itself accepted is
    // the wrong answer, and the vote is a heuristic that a subset still answers.
    const voting = @min(thread_count, max_thread_summaries);
    var summaries: [max_thread_summaries]ThreadSummary = undefined;
    var index: usize = 0;
    while (index < voting) : (index += 1) {
        fillThreadSummary(pool.threadTyped(index), &summaries[index]);
    }
    return pickBestThread(summaries[0..voting]);
}

// Return the worker of the vote-winning thread -- the value the search driver picks as
// `bestThread` when choosing the move to report.
pub fn bestThreadWorker(pool: *worker_layout.ThreadPool) *worker_layout.WorkerLayout {
    const idx = bestThreadIndex(pool);
    const thread = pool.threadAt(idx);
    return thread.worker.?;
}

test {
    @import("std").testing.refAllDecls(@This());
}
