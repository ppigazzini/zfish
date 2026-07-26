// Parse the "NumaPolicy" option string into a NumaConfig.
//
// Own the reader for the user-facing topology string ("a-b,c:d-e") and nothing else: the
// data structure, the system topology and the thread distribution stay in config.zig, so
// this file imports that one and nothing imports it back.
//
// Follow upstream's `from_string` + `indices_from_shortened_string` + `str_to_size_t`
// (numa.h, misc.cpp) shape for shape. The three disagree with a naive integer parse on
// more than the happy path -- a malformed element is dropped rather than fatal, a numeric
// prefix followed by whitespace is a value, and a repeated CPU rejects the whole string --
// so keeping the structure recognisable is what lets the two be read side by side.

const std = @import("std");

const config = @import("config.zig");
const NumaConfig = config.NumaConfig;

/// Parse a "NumaPolicy" string: nodes separated by ':', each a comma list of
/// CPU indices or ranges, e.g. "0-3,8:4-7" -> node0 {0,1,2,3,8}, node1 {4,5,6,7}.
///
/// Port upstream's `from_string` + `indices_from_shortened_string` (numa.h) shape for
/// shape, because the two disagree on more than the happy path:
///   * a MALFORMED element is skipped, not fatal -- "0,x,2" is node {0,2};
///   * a node string that yields no index leaves the node index unadvanced;
///   * only a repeated CPU (`addCpuToNode` false) rejects the whole string;
///   * parsing nothing at all (no node advanced) rejects it too.
pub fn parse(allocator: std.mem.Allocator, s: []const u8) error{ OutOfMemory, BadNuma }!NumaConfig {
    var cfg = NumaConfig.empty(allocator);
    errdefer cfg.deinit();

    var node: usize = 0;
    var node_it = std.mem.splitScalar(u8, s, ':');
    while (node_it.next()) |node_str| {
        if (try addShortenedIndices(&cfg, node, node_str)) node += 1;
    }
    if (node == 0) return error.BadNuma; // parsed no node at all
    cfg.custom_affinity = true;
    return cfg;
}

/// Add every CPU index a node string names, and report whether it named any (which is
/// what advances the node index). Port `indices_from_shortened_string`: walk the comma
/// list, read each element as one index or a `lo-hi` range, and DROP any element that
/// does not parse instead of failing the string.
fn addShortenedIndices(cfg: *NumaConfig, node: usize, node_str: []const u8) error{ OutOfMemory, BadNuma }!bool {
    // Bound one range element, as upstream does verbatim ("prevent oom"). Without it
    // `NumaPolicy 0-99999999999` walks 1e11 indices and the engine never answers.
    const max_indices: usize = 1 << 20;

    var any = false;
    var element_it = std.mem.splitScalar(u8, node_str, ',');
    while (element_it.next()) |element| {
        if (element.len == 0) continue;

        // Split on '-' the way upstream does: exactly one part is a lone index, exactly
        // two a range, and anything else ("1-2-3") is dropped.
        var part_it = std.mem.splitScalar(u8, element, '-');
        const first = part_it.next().?;
        const second = part_it.next();
        if (part_it.next() != null) continue; // three or more parts

        var lo: usize = undefined;
        var hi: usize = undefined;
        if (second) |last_part| {
            lo = strToSizeT(first) orelse continue;
            hi = strToSizeT(last_part) orelse continue;
            // Compare with wrapping subtraction, as the C unsigned expression does: a
            // reversed range wraps past max_indices and is dropped, not an error.
            if (hi -% lo >= max_indices) continue;
        } else {
            lo = strToSizeT(first) orelse continue;
            hi = lo;
        }

        var cpu = lo;
        while (cpu <= hi) : (cpu += 1) {
            if (!try cfg.addCpuToNode(node, cpu)) return error.BadNuma;
            any = true;
            if (cpu == std.math.maxInt(usize)) break; // do not wrap the loop counter
        }
    }
    return any;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn isSpaceByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == 0x0b or b == 0x0c or b == '\r';
}

fn strToSizeT(s: []const u8) ?usize {
    if (s.len == 0 or s[0] == '-') return null;

    var i: usize = 0;
    while (i < s.len and isSpaceByte(s[i])) i += 1;

    var negate = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        negate = s[i] == '-';
        i += 1;
    }

    var value: usize = 0;
    var digits: usize = 0;
    var overflow = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        digits += 1;
        const mul = @mulWithOverflow(value, 10);
        const add = @addWithOverflow(mul[0], s[i] - '0');
        if (mul[1] != 0 or add[1] != 0) overflow = true;
        value = add[0];
    }

    if (overflow) return null; // ERANGE
    // No digit converted: endptr stays at the original start, so test s[0], not s[i].
    const end = if (digits == 0) 0 else i;
    if (end < s.len and !isSpaceByte(s[end])) return null;
    if (digits == 0) return 0;

    return if (negate) 0 -% value else value;
}

test "parse parses ranges and lists into ordered nodes" {
    var cfg = try parse(testing.allocator, "0-3,8:4-7");
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.numNodes());
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 8 }, cfg.nodes.items[0].items);
    try testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7 }, cfg.nodes.items[1].items);
    try testing.expectEqual(@as(usize, 9), cfg.numCpus());
    try testing.expect(cfg.custom_affinity);
}

test "parse skips empty node segments without advancing the node index" {
    var cfg = try parse(testing.allocator, "0-1::2-3");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 2), cfg.numNodes());
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, cfg.nodes.items[0].items);
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, cfg.nodes.items[1].items);
}

test "strToSizeT reproduces strtoull, including the no-conversion endptr rule" {
    // Plain, and the trailing whitespace b4ea9205 allowed (the sysfs "\n" shape).
    try testing.expectEqual(@as(?usize, 7), strToSizeT("7"));
    try testing.expectEqual(@as(?usize, 7), strToSizeT("7 "));
    try testing.expectEqual(@as(?usize, 7), strToSizeT("7\n"));
    try testing.expectEqual(@as(?usize, 7), strToSizeT(" 7"));
    try testing.expectEqual(@as(?usize, 7), strToSizeT("+7"));
    // A numeric prefix followed by whitespace is the value; followed by anything else it
    // is a reject -- this is the pair the old parseInt call collapsed into one reject.
    try testing.expectEqual(@as(?usize, 7), strToSizeT("7 8"));
    try testing.expectEqual(@as(?usize, null), strToSizeT("7x"));
    // No conversion: endptr stays at byte 0, so the accept test reads s[0].
    try testing.expectEqual(@as(?usize, 0), strToSizeT(" x"));
    try testing.expectEqual(@as(?usize, null), strToSizeT("x"));
    // Rejected up front, before strtoull ever runs.
    try testing.expectEqual(@as(?usize, null), strToSizeT(""));
    try testing.expectEqual(@as(?usize, null), strToSizeT("-5"));
    // Overflow is ERANGE.
    try testing.expectEqual(@as(?usize, null), strToSizeT("99999999999999999999999"));
}

test "parse drops a malformed element instead of failing the whole string" {
    // Upstream keeps parsing past an element str_to_size_t rejects.
    var cfg = try parse(testing.allocator, "0,x,2");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.numNodes());
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, cfg.nodes.items[0].items);

    // Interior whitespace: upstream reads the numeric prefix, so "0 1" is 0.
    var interior = try parse(testing.allocator, "0 1,2");
    defer interior.deinit();
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, interior.nodes.items[0].items);

    // Three or more '-' parts is neither an index nor a range: dropped.
    var three = try parse(testing.allocator, "0,1-2-3");
    defer three.deinit();
    try testing.expectEqualSlices(usize, &.{0}, three.nodes.items[0].items);
}

test "parse rejects a repeated cpu, an all-malformed string, and a reversed range" {
    // A repeat is fatal even onto the same node (upstream's is_cpu_assigned test).
    try testing.expectError(error.BadNuma, parse(testing.allocator, "0,0"));
    // Nothing parsed at all -> no node advanced -> reject.
    try testing.expectError(error.BadNuma, parse(testing.allocator, "x"));
    try testing.expectError(error.BadNuma, parse(testing.allocator, "1-2-3"));
    // hi < lo wraps past max_indices, so the element is dropped and nothing is parsed.
    try testing.expectError(error.BadNuma, parse(testing.allocator, "3-0"));
}

test "parse bounds a huge range instead of walking it" {
    // Upstream's `constexpr usize MaxIndices = 1 << 20;  // prevent oom`. Without it this
    // call walks 1e11 indices and never returns -- the engine stops answering `isready`.
    try testing.expectError(error.BadNuma, parse(testing.allocator, "0-99999999999"));
    // The bound is on the SPAN, so a large-but-in-range window still parses.
    var ok = try parse(testing.allocator, "1000000-1000003");
    defer ok.deinit();
    try testing.expectEqualSlices(usize, &.{ 1000000, 1000001, 1000002, 1000003 }, ok.nodes.items[0].items);
}

test "parse rejects malformed input" {
    try testing.expectError(error.BadNuma, parse(testing.allocator, "3-1")); // reject hi<lo
    try testing.expectError(error.BadNuma, parse(testing.allocator, "x"));
}

test "parse unwinds leak-free on every allocation failure" {
    const T = struct {
        fn run(a: std.mem.Allocator) !void {
            var cfg = try parse(a, "0-3,8:4-7");
            cfg.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, T.run, .{});
}
