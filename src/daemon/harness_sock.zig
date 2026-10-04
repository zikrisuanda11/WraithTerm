//! Daemon harness socket (P2.4, D6).
//!
//! One Unix socket per daemon (`wraith-harness-<daemonid>.sock`,
//! `0600`, beside the control socket) where omp bridges (P2.5) write
//! JSON-lines state events. Lines are parsed with `harness_event`
//! and dispatched to the matching session by `session_id`.
//!
//! Linux-only in v1, like the rest of `src/daemon`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const event = @import("harness_event.zig");
const sock = @import("socket.zig");

/// Env names injected into every daemon-spawned child (D6).
pub const sock_env = "WRAITH_HARNESS_SOCK";
pub const session_env = "WRAITH_SESSION_ID";

/// Per-session harness state: last Tier 1 report from the bridge.
/// `tool` is a fixed buffer (no per-event allocation on the hot
/// path); longer names truncate, documented.
pub const HarnessState = struct {
    state: event.State = .unknown,
    tool_buf: [128]u8 = undefined,
    tool_len: usize = 0,

    pub fn tool(self: *const HarnessState) ?[]const u8 {
        if (self.tool_len == 0) return null;
        return self.tool_buf[0..self.tool_len];
    }

    pub fn apply(self: *HarnessState, ev: event.Event) void {
        self.state = ev.state;
        if (ev.tool) |t| {
            const n = @min(t.len, self.tool_buf.len);
            @memcpy(self.tool_buf[0..n], t[0..n]);
            self.tool_len = n;
        } else {
            self.tool_len = 0;
        }
    }
};

/// Read one line (no newline) from `fd` into `buf`. Returns the
/// length, or null on clean EOF with no partial data. Lines longer
/// than `buf` are drained to the newline and reported as
/// `error.LineTooLong` so one long line cannot desync the rest.
pub fn readLine(fd: linux.socket_t, buf: []u8) !?usize {
    var n: usize = 0;
    var tmp: [1]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &tmp, 1);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            const e: linux.E = @enumFromInt(-signed);
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        if (signed == 0) return if (n == 0) null else n;
        if (tmp[0] == '\n') return n;
        if (n < buf.len) {
            buf[n] = tmp[0];
            n += 1;
        } else {
            // Over the cap: drain to the newline, then report.
            while (true) {
                const rc2 = linux.read(fd, &tmp, 1);
                const s2: isize = @bitCast(rc2);
                if (s2 < 0) {
                    const e2: linux.E = @enumFromInt(-s2);
                    if (e2 == .INTR) continue;
                    return error.ReadFailed;
                }
                if (s2 == 0 or tmp[0] == '\n') break;
            }
            return error.LineTooLong;
        }
    }
}

/// Line pump for bridge connections; the daemon (`server.zig`)
/// inlines its own accept loop around `readLine` so dispatch has
/// session context. Kept here: `readLine`, `HarnessState`,
/// `listenerPath`.
/// Listener path for a daemon: sibling of the control socket.
pub fn listenerPath(
    alloc: Allocator,
    control_path: []const u8,
    daemon_id: []const u8,
) ![]u8 {
    const dir = std.fs.path.dirname(control_path) orelse ".";
    return std.fmt.allocPrint(alloc, "{s}/wraith-harness-{s}.sock", .{ dir, daemon_id });
}

test "harness: state apply and tool truncation" {
    const testing = std.testing;
    var hs = HarnessState{};
    try testing.expectEqual(event.State.unknown, hs.state);
    try testing.expect(hs.tool() == null);
    hs.apply(.{ .state = .executing_tool, .tool = "edit" });
    try testing.expectEqual(event.State.executing_tool, hs.state);
    try testing.expectEqualStrings("edit", hs.tool().?);
    // Tool cleared when the next event carries none.
    hs.apply(.{ .state = .idle });
    try testing.expectEqual(event.State.idle, hs.state);
    try testing.expect(hs.tool() == null);
    // Absurd tool names truncate to the buffer, never panic.
    var long: [300]u8 = undefined;
    @memset(&long, 't');
    hs.apply(.{ .state = .executing_tool, .tool = &long });
    try testing.expectEqual(@as(usize, 128), hs.tool().?.len);
}

test "harness: readLine caps and drains" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]linux.socket_t = undefined;
    {
        const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
        const signed: isize = @bitCast(rc);
        try testing.expect(signed == 0);
    }
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }
    const w = fds[0];
    const r = fds[1];
    _ = linux.write(w, "short\n", 6);
    _ = linux.write(w, "0123456789ABCDEF\n", 17);
    _ = linux.write(w, "tail\n", 5);
    var buf: [8]u8 = undefined;
    // Fits.
    try testing.expectEqual(@as(?usize, 5), try readLine(r, &buf));
    try testing.expectEqualStrings("short", buf[0..5]);
    // 16 bytes vs 8-byte buf: drained + reported, stream intact.
    try testing.expectError(error.LineTooLong, readLine(r, &buf));
    try testing.expectEqual(@as(?usize, 4), try readLine(r, &buf));
    try testing.expectEqualStrings("tail", buf[0..4]);
    // Clean EOF.
    _ = linux.close(w);
    fds[0] = -1;
    try testing.expectEqual(@as(?usize, null), try readLine(r, &buf));
}
