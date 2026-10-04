//! WraithTerm session identifiers.
//!
//! A session ID names one daemon-owned terminal session. It appears in
//! the CLI, on the IPC wire, and in socket paths, so it is fixed at
//! 8 lowercase hex characters (4 bytes of CSPRNG entropy). IDs are
//! generated from a real CSPRNG via `terminal.sys.randomSecure`; no
//! weaker fallback exists (see that file's contract).
const std = @import("std");
const sys = @import("../terminal/sys.zig");

/// A session identifier. Always exactly 8 lowercase hex characters.
pub const SessionId = struct {
    bytes: [4]u8,

    pub const len = 8;

    /// Generate a new random ID.
    pub fn generate(io: std.Io) SessionId {
        var id: SessionId = undefined;
        // The only failure mode is entropy unavailability. A session ID is
        // not a secret per se, but callers should treat inability to get
        // entropy as fatal rather than silently using weak randomness.
        sys.randomSecure(io, &id.bytes) catch
            @panic("wraith: no secure entropy for session ID");
        return id;
    }

    /// Parse an 8-character lowercase hex string.
    pub fn parse(s: []const u8) error{Invalid}!SessionId {
        if (s.len != len) return error.Invalid;
        var id: SessionId = undefined;
        for (&id.bytes, 0..) |*b, i| {
            const hi = hexDigit(s[i * 2]) orelse return error.Invalid;
            const lo = hexDigit(s[i * 2 + 1]) orelse return error.Invalid;
            b.* = (hi << 4) | lo;
        }
        return id;
    }

    fn hexDigit(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => null,
        };
    }

    /// Write the 8-character hex representation into `buf`.
    pub fn toString(self: SessionId, buf: *[len]u8) []const u8 {
        const hex = "0123456789abcdef";
        for (self.bytes, 0..) |b, i| {
            buf[i * 2] = hex[b >> 4];
            buf[i * 2 + 1] = hex[b & 0x0f];
        }
        return buf;
    }

    pub fn format(
        self: SessionId,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var buf: [len]u8 = undefined;
        try writer.writeAll(self.toString(&buf));
    }

    pub fn eql(a: SessionId, b: SessionId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

test "SessionId: round trip" {
    const testing = std.testing;
    const id = SessionId{ .bytes = .{ 0xde, 0xad, 0xbe, 0xef } };
    var buf: [SessionId.len]u8 = undefined;
    try testing.expectEqualStrings("deadbeef", id.toString(&buf));

    const parsed = try SessionId.parse("deadbeef");
    try testing.expect(id.eql(parsed));
}

test "SessionId: parse rejects bad input" {
    const testing = std.testing;
    try testing.expectError(error.Invalid, SessionId.parse("deadbee")); // 7
    try testing.expectError(error.Invalid, SessionId.parse("deadbeef0")); // 9
    try testing.expectError(error.Invalid, SessionId.parse("DEADBEEF")); // uppercase
    try testing.expectError(error.Invalid, SessionId.parse("deadbeez")); // non-hex
    try testing.expectError(error.Invalid, SessionId.parse(""));
}

test "SessionId: generate produces parseable unique ids" {
    const testing = std.testing;
    var seen: [16]SessionId = undefined;
    for (&seen) |*slot| {
        slot.* = SessionId.generate(testing.io);
        var buf: [SessionId.len]u8 = undefined;
        // Every generated ID must survive a round trip through its own
        // string form (what the CLI and wire use).
        const parsed = try SessionId.parse(slot.toString(&buf));
        try testing.expect(parsed.eql(slot.*));
    }
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| try testing.expect(!a.eql(b));
    }
}

test "SessionId: format matches toString" {
    const testing = std.testing;
    const id = SessionId{ .bytes = .{ 0x00, 0x01, 0x0f, 0xff } };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{id});
    const out = w.buffered();
    var expect: [SessionId.len]u8 = undefined;
    try testing.expectEqualStrings(id.toString(&expect), out);
}
