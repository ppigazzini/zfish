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
    is_inexact: u8,
    score: i32,
    pv_length: usize,
};

// Write a neutral record for a thread with no Worker rather than leaving the caller's slot
// untouched: the slot would stay `undefined` and pickBestThread reads .score/.pv_length out
// of it, making best-thread selection depend on stack garbage.
fn fillThreadSummary(thread: *worker_layout.Thread, out: *ThreadSummary) void {
    const w = worker_layout.Worker.fromThread(thread) orelse {
        out.* = .{
            .pv0_raw = 0,
            .is_inexact = 1,
            .score = value_none,
            .pv_length = 0,
        };
        return;
    };
    const rmv = w.rootMovesFirst();
    out.pv0_raw = rmv.pv.at(0);
    out.is_inexact = @intFromBool(rmv.inexact_lower or rmv.inexact_upper);
    out.score = rmv.score;
    out.pv_length = rmv.pv.length;
}

// Accumulate in i64 to match upstream's `unordered_map<Move, i64>` vote tally (thread.cpp:355).
fn voteForMove(summaries: []const ThreadSummary, move_raw: u16, min_score: i32) i64 {
    var vote: i64 = 0;
    var index: usize = 0;
    while (index < summaries.len) : (index += 1) {
        if (summaries[index].pv0_raw == move_raw)
            vote += threadVotingValue(summaries[index], min_score);
    }
    return vote;
}

// upstream thread.cpp:363 -- `score - minScore + 14`, no depth weighting.
fn threadVotingValue(summary: ThreadSummary, min_score: i32) i64 {
    return @as(i64, summary.score - min_score + 14);
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
    return summary.score != -value_infinite and isDecisive(summary.score) and summary.is_inexact == 0;
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

        if (best_decisive) {
            if (current_decisive and absInt(current.score) > absInt(best.score)) {
                best_index = index;
            }
        } else if (current_decisive or
            (!isLoss(current.score) and
                // upstream thread.cpp:396 -- tie broken by the raw PV length, not a voting value.
                (current_vote > best_vote or (current_vote == best_vote and current.pv_length > best.pv_length))))
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

// ---- pickBestThread ---------------------------------------------------------
//
// This function chooses the move actually PLAYED whenever Threads > 1, and nothing else
// in the tree can see it: bench is single-threaded, so the loop trivially returns 0 and
// every value gate agrees no matter what the vote arithmetic does. refAllDecls above
// compiles it and exercises nothing. The cases below are derived from upstream's
// `ThreadPool::get_best_thread` (thread.cpp:349) by hand, not from this implementation --
// a test read off the code under test would pin whatever it already does.

const testing = @import("std").testing;

fn ts(pv0: u16, score: i32, pv_len: usize, bound: u8) ThreadSummary {
    return .{ .pv0_raw = pv0, .is_inexact = bound, .score = score, .pv_length = pv_len };
}

test "pickBestThread: two agreeing threads outvote one scoring higher" {
    // The `+ 14` floor is what makes agreement count. min = 10, so move A scores
    // (0+14)+(0+14) = 28 and move B scores (2+14) = 16: agreement wins despite B's
    // higher score. Drop the floor and A collects 0 while B collects 2, flipping it.
    const s = [_]ThreadSummary{
        ts(100, 10, 2, 0),
        ts(100, 10, 2, 0),
        ts(200, 12, 2, 0),
    };
    try testing.expectEqual(@as(usize, 0), pickBestThread(&s));
}

test "pickBestThread: a lone thread far enough ahead still wins" {
    // min = 10 -> votes A 14, B 104. The floor biases toward agreement, it does not
    // override a real score gap.
    const s = [_]ThreadSummary{
        ts(100, 10, 2, 0),
        ts(200, 100, 2, 0),
    };
    try testing.expectEqual(@as(usize, 1), pickBestThread(&s));
}

test "pickBestThread: an equal vote is broken by the longer PV" {
    // upstream thread.cpp:396 -- `newThreadMove.pv.size() > bestThreadMove.pv.size()`,
    // the RAW length, not a voting value.
    const longer = [_]ThreadSummary{
        ts(100, 10, 3, 0),
        ts(200, 10, 5, 0),
    };
    try testing.expectEqual(@as(usize, 1), pickBestThread(&longer));

    const shorter = [_]ThreadSummary{
        ts(100, 10, 5, 0),
        ts(200, 10, 3, 0),
    };
    try testing.expectEqual(@as(usize, 0), pickBestThread(&shorter));
}

test "pickBestThread: between two decisive threads the shorter mate wins" {
    // Both decisive -> take the LARGER absolute score, which is the shorter mate.
    const s = [_]ThreadSummary{
        ts(100, 31900, 2, 0),
        ts(200, 31950, 2, 0),
    };
    try testing.expectEqual(@as(usize, 1), pickBestThread(&s));

    // ...and the deeper mate does not displace the shorter one.
    const reversed = [_]ThreadSummary{
        ts(100, 31950, 2, 0),
        ts(200, 31900, 2, 0),
    };
    try testing.expectEqual(@as(usize, 0), pickBestThread(&reversed));
}

test "pickBestThread: a decisive thread is not displaced on votes alone" {
    // best is decisive, so the ONLY thing that can replace it is a shorter decisive
    // score -- a non-decisive thread cannot, however the vote falls.
    const s = [_]ThreadSummary{
        ts(100, 31900, 2, 0),
        ts(200, 20, 9, 0),
        ts(200, 20, 9, 0),
    };
    try testing.expectEqual(@as(usize, 0), pickBestThread(&s));
}

test "pickBestThread: an inexact score does not count as decisive" {
    // upstream guards decisiveness with `!is_inexact()`: an aborted search can report
    // an inexact win. Thread 0 holds the larger mate score but it is INEXACT, so it is not
    // decisive and thread 1's genuine mate takes it. Were the inexact flag ignored, thread 0
    // would count as decisive and keep the pick, since |31900| < |31950| -- so this case
    // separates the two readings.
    const s = [_]ThreadSummary{
        ts(100, 31950, 2, 1),
        ts(200, 31900, 2, 0),
    };
    try testing.expectEqual(@as(usize, 1), pickBestThread(&s));
}

test "pickBestThread: a losing thread cannot take the pick on votes" {
    // Both scores are losses and both are bounds, so neither is decisive and the vote
    // branch is the one that runs. `!is_loss(newThreadMove.score)` blocks the swap even
    // though thread 1 outvotes thread 0 (114 against 14) -- drop that guard and the engine
    // plays the move it believes loses faster.
    const s = [_]ThreadSummary{
        ts(100, -31700, 2, 1),
        ts(200, -31600, 2, 1),
    };
    try testing.expectEqual(@as(usize, 0), pickBestThread(&s));
}

test "pickBestThread: a single thread is its own winner" {
    const s = [_]ThreadSummary{ts(100, 42, 3, 0)};
    try testing.expectEqual(@as(usize, 0), pickBestThread(&s));
}
