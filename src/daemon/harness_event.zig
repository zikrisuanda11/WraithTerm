//! D6 harness event schema + JSON-lines parser (P2.3).
//!
//! The omp bridge (P2.5) writes one JSON object per line, ≤ 4 KiB,
//! to the daemon's harness socket (D6):
//! `{"v":1,"type":"state","state":"…","tool":"…?",…}`.
//! Malformed lines are skipped, never fatal: a chatty or buggy
//! bridge must not break the daemon.
//!
//! Parsing reuses the repo's `std.json.parseFromSliceLeaky` pattern
//! (`src/crash/sentry_envelope.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum accepted line length, including the newline (D6/P2.3).
pub const max_line_bytes: usize = 4096;

/// Harness states on the D6 wire (matches `HARNESS_OMP.md` §4).
pub const State = enum {
    idle,
    thinking,
    executing_tool,
    awaiting_approval,
    @"error",
    unknown,

    pub fn fromName(s: []const u8) ?State {
        if (std.mem.eql(u8, s, "idle")) return .idle;
        if (std.mem.eql(u8, s, "thinking")) return .thinking;
        if (std.mem.eql(u8, s, "executing_tool")) return .executing_tool;
        if (std.mem.eql(u8, s, "awaiting_approval")) return .awaiting_approval;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        if (std.mem.eql(u8, s, "unknown")) return .unknown;
        return null;
    }

    /// Wire ordinal from `codec.HarnessListEntry.tier1`
    /// (`@intFromEnum` order). Unknown values map to null (the
    /// caller renders them, never crashes on them).
    pub fn fromOrdinal(v: u8) ?State {
        return std.enums.fromInt(State, v);
    }
};

/// A decoded state event. `tool` is borrowed from the parse arena
/// (see `parseLine`); `session_id` is empty when the bridge omitted
/// it (older bridges predate the field).
pub const Event = struct {
    state: State,
    tool: ?[]const u8 = null,
    session_id: []const u8 = "",
    omp_version: []const u8 = "",
};

/// Why a line was skipped. Returned, not logged: the daemon counts
/// or drops these silently (a bridge bug must not spam the log).
pub const SkipReason = enum {
    too_long,
    not_json,
    not_object,
    bad_version,
    bad_type,
    bad_state,
};

/// Parse one JSON-lines event. `line` excludes the trailing newline
/// (tolerated if present). String fields are duped into `arena`;
/// numbers/bools are ignored. Returns the event or the reason it
/// was skipped.
pub fn parseLine(arena: Allocator, line: []const u8) union(enum) {
    ok: Event,
    skip: SkipReason,
} {
    const text = std.mem.trim(u8, line, "\r\n");
    if (text.len > max_line_bytes) return .{ .skip = .too_long };
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        text,
        .{ .allocate = .alloc_if_needed },
    ) catch return .{ .skip = .not_json };
    const obj = switch (value) {
        .object => |map| map,
        else => return .{ .skip = .not_object },
    };
    const v = obj.get("v") orelse return .{ .skip = .bad_version };
    if (v != .integer or v.integer != 1) return .{ .skip = .bad_version };
    const t = obj.get("type") orelse return .{ .skip = .bad_type };
    if (t != .string or !std.mem.eql(u8, t.string, "state")) {
        return .{ .skip = .bad_type };
    }
    const s = obj.get("state") orelse return .{ .skip = .bad_state };
    if (s != .string) return .{ .skip = .bad_state };
    const state = State.fromName(s.string) orelse return .{ .skip = .bad_state };
    var ev = Event{ .state = state };
    if (obj.get("tool")) |tool| {
        if (tool == .string and tool.string.len > 0) ev.tool = tool.string;
    }
    if (obj.get("session_id")) |sid| {
        if (sid == .string) ev.session_id = sid.string;
    }
    if (obj.get("omp_version")) |ver| {
        if (ver == .string) ev.omp_version = ver.string;
    }
    return .{ .ok = ev };
}

/// Split a byte stream into lines and parse each, calling `handle`
/// for ok events. Lines over the cap are skipped whole (the reader
/// drains to the next newline so one long line cannot desync the
/// rest). Returns the counts.
pub fn parseStream(
    arena: Allocator,
    data: []const u8,
    handle: *const fn (Event) void,
) struct { ok: usize, skipped: usize } {
    var ok: usize = 0;
    var skipped: usize = 0;
    var rest = data;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        rest = if (nl) |i| rest[i + 1 ..] else &.{};
        switch (parseLine(arena, line)) {
            .ok => |ev| {
                handle(ev);
                ok += 1;
            },
            .skip => skipped += 1,
        }
    }
    return .{ .ok = ok, .skipped = skipped };
}

test "event: full state line parses" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = parseLine(arena.allocator(),
        \\{"v":1,"type":"state","state":"executing_tool","tool":"edit","session_id":"abc","omp_version":"18.4.4","ts":123}
    );
    try testing.expect(r == .ok);
    try testing.expectEqual(State.executing_tool, r.ok.state);
    try testing.expectEqualStrings("edit", r.ok.tool.?);
    try testing.expectEqualStrings("abc", r.ok.session_id);
    try testing.expectEqualStrings("18.4.4", r.ok.omp_version);
}

test "event: minimal line, optional fields empty" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = parseLine(arena.allocator(), "{\"v\":1,\"type\":\"state\",\"state\":\"idle\"}");
    try testing.expect(r == .ok);
    try testing.expectEqual(State.idle, r.ok.state);
    try testing.expect(r.ok.tool == null);
    try testing.expectEqualStrings("", r.ok.session_id);
}

test "event: all six states round-trip" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = [_][]const u8{ "idle", "thinking", "executing_tool", "awaiting_approval", "error", "unknown" };
    for (names) |name| {
        const line = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"v\":1,\"type\":\"state\",\"state\":\"{s}\"}}",
            .{name},
        );
        defer testing.allocator.free(line);
        const r = parseLine(arena.allocator(), line);
        try testing.expect(r == .ok);
        try testing.expectEqual(State.fromName(name).?, r.ok.state);
    }
}

test "event: malformed lines skipped with reasons" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Not JSON.
    try testing.expectEqual(SkipReason.not_json, parseLine(alloc, "hello{").skip);
    // JSON but not an object.
    try testing.expectEqual(SkipReason.not_object, parseLine(alloc, "[1,2]").skip);
    try testing.expectEqual(SkipReason.not_object, parseLine(alloc, "42").skip);
    // Missing/wrong version.
    try testing.expectEqual(SkipReason.bad_version, parseLine(alloc, "{\"type\":\"state\",\"state\":\"idle\"}").skip);
    try testing.expectEqual(SkipReason.bad_version, parseLine(alloc, "{\"v\":2,\"type\":\"state\",\"state\":\"idle\"}").skip);
    // Wrong type.
    try testing.expectEqual(SkipReason.bad_type, parseLine(alloc, "{\"v\":1,\"type\":\"ping\",\"state\":\"idle\"}").skip);
    // Unknown state.
    try testing.expectEqual(SkipReason.bad_state, parseLine(alloc, "{\"v\":1,\"type\":\"state\",\"state\":\"flying\"}").skip);
    try testing.expectEqual(SkipReason.bad_state, parseLine(alloc, "{\"v\":1,\"type\":\"state\"}").skip);
    // Over the 4 KiB cap.
    var long: [max_line_bytes + 16]u8 = undefined;
    @memset(&long, 'x');
    try testing.expectEqual(SkipReason.too_long, parseLine(alloc, &long).skip);
}

test "event: stream mixes ok and malformed" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const seen = struct {
        var states: [4]State = undefined;
        var n: usize = 0;
        fn handle(ev: Event) void {
            states[n] = ev.state;
            n += 1;
        }
    };
    const counts = parseStream(
        arena.allocator(),
        \\{"v":1,"type":"state","state":"thinking"}
        \\not json at all
        \\{"v":1,"type":"state","state":"awaiting_approval","tool":"ask"}
        \\{"v":9,"type":"state","state":"idle"}
    ,
        &seen.handle,
    );
    try testing.expectEqual(@as(usize, 2), counts.ok);
    try testing.expectEqual(@as(usize, 2), counts.skipped);
    try testing.expectEqual(@as(usize, 2), seen.n);
    try testing.expectEqual(State.thinking, seen.states[0]);
    try testing.expectEqual(State.awaiting_approval, seen.states[1]);
}
