//! SSH bootstrap + UDP handshake (P4.3, D2, Mosh pattern).
//!
//! Client: `wraith --remote user@host[:port]` runs
//! `ssh user@host wraith --remote-server`; the server prints one
//! line `WRAITH CONNECT <udp_port> <base64_session_key>` and waits
//! for the first UDP packet. The client parses that line (60 s
//! deadline), then speaks UDP and drops SSH.
//!
//! - Session key: 32 CSPRNG bytes, session-lived only, never logged
//!   (only its base64 crosses SSH, which is already encrypted).
//! - Server self-closes with no authenticated client in the first
//!   60 s (D2); the 7-day idle rule belongs to the session loop
//!   (P4.4+, configurable).
//! - Pure parsing + deadline math here; process/UDP IO at the edges.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Server handshake line prefix (D2).
pub const connect_prefix = "WRAITH CONNECT ";
/// Client wait for the CONNECT line (D2: 60 s).
pub const connect_timeout_ns: u64 = 60 * std.time.ns_per_s;
/// Base64 (standard alphabet) length of a 32-byte key.
pub const key_b64_len = 44;

/// Parsed `WRAITH CONNECT` line.
pub const ConnectInfo = struct {
    udp_port: u16,
    key: [32]u8,
};

pub const ParseError = error{
    NotConnectLine,
    BadPort,
    BadKey,
    Trailing,
};

/// Parse one `WRAITH CONNECT <port> <b64key>` line (no newline).
/// Rejects trailing garbage (a noisy SSH banner sharing the line
/// would otherwise smuggle bytes into the key exchange).
pub fn parseConnectLine(line: []const u8) ParseError!ConnectInfo {
    if (!std.mem.startsWith(u8, line, connect_prefix)) return error.NotConnectLine;
    var rest = line[connect_prefix.len..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadPort;
    const port = std.fmt.parseInt(u16, rest[0..sp], 10) catch return error.BadPort;
    rest = rest[sp + 1 ..];
    if (rest.len != key_b64_len) return error.BadKey;
    var key: [32]u8 = undefined;
    std.base64.standard.Decoder.decode(&key, rest) catch return error.BadKey;
    return .{ .udp_port = port, .key = key };
}

/// Format the server line for a bound port + key (server side).
/// Caller owns the returned slice.
pub fn formatConnectLine(alloc: Allocator, udp_port: u16, key: [32]u8) ![]u8 {
    var b64: [key_b64_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &key);
    return std.fmt.allocPrint(alloc, "{s}{d} {s}", .{ connect_prefix, udp_port, b64 });
}

/// Elapsed-deadline check on a virtual clock (tests) or real clock
/// (production passes `now_ns` from `Timestamp.now`).
pub fn deadlineExceeded(start_ns: u64, now_ns: u64, timeout_ns: u64) bool {
    return now_ns >= start_ns and now_ns - start_ns > timeout_ns;
}

/// Read a child's stdout until the first valid CONNECT line (SSH
/// banners and junk lines are skipped), the deadline passes, or EOF.
/// Linux-only (raw poll on the pipe fd). `file` must be nonblocking
/// or this blocks in `read`; callers pass the child-stdout pipe as
/// opened by `std.process.spawn` (blocking is fine — poll gates).
pub fn readConnectLine(
    alloc: Allocator,
    io: std.Io,
    file: std.Io.File,
    deadline_ns: u64,
) !ConnectInfo {
    const linux = std.os.linux;
    const start = std.Io.Timestamp.now(io, .awake);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(alloc);
    var fds = [_]std.posix.pollfd{.{
        .fd = file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var tmp: [512]u8 = undefined;
    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        const since_start: u64 = @intCast(@max(start.durationTo(now).toNanoseconds(), 0));
        if (since_start > deadline_ns) return error.Timeout;
        const remain_ms: i32 = @intCast(@min(
            @divFloor(deadline_ns - since_start, std.time.ns_per_ms) + 1,
            std.math.maxInt(i32),
        ));
        const n = std.posix.poll(&fds, @min(remain_ms, 50)) catch return error.PollFailed;
        if (n == 0) continue;
        const rc = linux.read(file.handle, &tmp, tmp.len);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            const e: linux.E = @enumFromInt(-signed);
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        if (signed == 0) return error.NotFound;
        const chunk = tmp[0..@as(usize, @intCast(signed))];
        try acc.appendSlice(alloc, chunk);
        while (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl| {
            // Copy the line out before shifting the buffer.
            var line_buf: [key_b64_len + 64]u8 = undefined;
            const line_len = @min(nl, line_buf.len);
            @memcpy(line_buf[0..line_len], acc.items[0..line_len]);
            const rest_len = acc.items.len - nl - 1;
            std.mem.copyForwards(u8, acc.items[0..rest_len], acc.items[nl + 1 ..]);
            acc.items.len = rest_len;
            const trimmed = std.mem.trim(u8, line_buf[0..line_len], " \t\r");
            if (trimmed.len == 0) continue;
            if (parseConnectLine(trimmed)) |info| return info else |_| {}
        }
    }
}

test "bootstrap: format then parse round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 256);
    const line = try formatConnectLine(alloc, 60123, key);
    defer alloc.free(line);
    try testing.expect(std.mem.startsWith(u8, line, "WRAITH CONNECT 60123 "));
    try testing.expectEqual(@as(usize, 15 + 5 + 1 + key_b64_len), line.len);
    const back = try parseConnectLine(line);
    try testing.expectEqual(@as(u16, 60123), back.udp_port);
    try testing.expectEqualSlices(u8, &key, &back.key);
}

test "bootstrap: malformed lines rejected" {
    const testing = std.testing;
    try testing.expectError(error.NotConnectLine, parseConnectLine("hello"));
    try testing.expectError(error.NotConnectLine, parseConnectLine("WRAITH CONNECTX 1 AAAA"));
    try testing.expectError(error.BadPort, parseConnectLine("WRAITH CONNECT abc AAAA"));
    try testing.expectError(error.BadPort, parseConnectLine("WRAITH CONNECT 99999 AAAA"));
    try testing.expectError(error.BadPort, parseConnectLine("WRAITH CONNECT 123"));
    try testing.expectError(error.BadKey, parseConnectLine("WRAITH CONNECT 123 " ++ "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try testing.expectError(error.BadKey, parseConnectLine("WRAITH CONNECT 123 " ++ "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"));
    try testing.expectError(error.BadKey, parseConnectLine("WRAITH CONNECT 123 " ++ "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "));
}

test "bootstrap: deadline math" {
    const testing = std.testing;
    try testing.expect(!deadlineExceeded(0, 59_999_999_999, connect_timeout_ns));
    try testing.expect(deadlineExceeded(0, 60_000_000_001, connect_timeout_ns));
    try testing.expect(!deadlineExceeded(1_000, 1_000 + connect_timeout_ns, connect_timeout_ns));
}

test "bootstrap: fake ssh banner plus connect" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    // Fake "ssh": banner lines, then a valid CONNECT line.
    var key: [32]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast((i * 13 + 1) % 256);
    const line = try formatConnectLine(alloc, 43210, key);
    defer alloc.free(line);
    const script = try std.fmt.allocPrint(
        alloc,
        "printf 'OpenSSH_9.9 fake banner\\nWarning: motd\\n'; printf '{s}\\n'",
        .{line},
    );
    defer alloc.free(script);
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer _ = child.wait(testing.io) catch {};
    const out = child.stdout orelse return error.NoPipe;
    const info = try readConnectLine(alloc, testing.io, out, 10 * std.time.ns_per_s);
    try testing.expectEqual(@as(u16, 43210), info.udp_port);
    try testing.expectEqualSlices(u8, &key, &info.key);
}

test "bootstrap: banner only means not found" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'banner\\nno connect here\\n'" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer _ = child.wait(testing.io) catch {};
    const out = child.stdout orelse return error.NoPipe;
    try testing.expectError(
        error.NotFound,
        readConnectLine(alloc, testing.io, out, 10 * std.time.ns_per_s),
    );
}

test "bootstrap: slow connect hits the deadline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    // CONNECT arrives after 3 s; the reader gives up after 300 ms.
    // The child is killed afterwards (no hang).
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 3; printf 'WRAITH CONNECT 1 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n'" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        // Kill reaps the sleeper; no wait afterwards (id is gone).
        child.kill(testing.io);
    }
    const out = child.stdout orelse return error.NoPipe;
    try testing.expectError(
        error.Timeout,
        readConnectLine(alloc, testing.io, out, 300 * std.time.ns_per_ms),
    );
}
