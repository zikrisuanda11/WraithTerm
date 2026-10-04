//! Daemon screen snapshot: encode a live terminal into chunked
//! `codec` Snapshot messages and restore them back (P1.5, D4).
//!
//! The grid/scrollback bytes reuse Ghostty's own snapshot format
//! (`terminal/snapshot`: encode → decode round-trips the full
//! terminal including history). This module only chunks the opaque
//! bytes into `codec.Message.snapshot` frames so they fit the 1 MiB
//! local message limit, and fills the routing header (state id,
//! size, cursor, chunk index) the live protocol needs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("../terminal/Terminal.zig");
const snapshot = @import("../terminal/snapshot/snapshot.zig");
const codec = @import("codec.zig");

/// Max payload bytes per Snapshot message. Well under the 1 MiB
/// codec limit, leaving room for frame + message headers.
pub const default_chunk_bytes: usize = 64 * 1024;

/// A taken snapshot: the raw encoded bytes plus one codec message
/// per chunk. Message payloads slice into `bytes`.
pub const Take = struct {
    bytes: []u8,
    messages: []codec.Message,

    pub fn deinit(self: *Take, alloc: Allocator) void {
        alloc.free(self.bytes);
        alloc.free(self.messages);
    }
};

/// Flag bit: the snapshot was taken while the alternate screen was active.
pub const flag_alt_screen: u8 = 0x01;

/// Encode `term` (active screen + scrollback) and split into chunks
/// of at most `max_chunk_bytes` payload each.
pub fn take(
    alloc: Allocator,
    term: *const Terminal,
    state_id: u32,
    max_chunk_bytes: usize,
) (Allocator.Error || snapshot.EncodeError)!Take {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try snapshot.encode(alloc, &out.writer, term, .{ .continuation = .ground });

    const bytes = try out.toOwnedSlice();
    errdefer alloc.free(bytes);

    const screen = term.screens.active;
    const flags: u8 = if (term.screens.active_key == .alternate) flag_alt_screen else 0;
    const count: u16 = @intCast((bytes.len + max_chunk_bytes - 1) / max_chunk_bytes);
    const messages = try alloc.alloc(codec.Message, @max(count, 1));
    errdefer alloc.free(messages);

    if (bytes.len == 0) {
        messages[0] = .{ .snapshot = .{
            .state_id = state_id,
            .cols = term.cols,
            .rows = term.rows,
            .cursor_x = screen.cursor.x,
            .cursor_y = screen.cursor.y,
            .flags = flags,
            .cursor_style = @intFromEnum(screen.cursor.cursor_style),
            .chunk_index = 0,
            .chunk_count = 1,
            .payload = &.{},
        } };
        return .{ .bytes = bytes, .messages = messages };
    }

    var i: u16 = 0;
    var off: usize = 0;
    while (off < bytes.len) : (i += 1) {
        const end = @min(off + max_chunk_bytes, bytes.len);
        messages[i] = .{ .snapshot = .{
            .state_id = state_id,
            .cols = term.cols,
            .rows = term.rows,
            .cursor_x = screen.cursor.x,
            .cursor_y = screen.cursor.y,
            .flags = flags,
            .cursor_style = @intFromEnum(screen.cursor.cursor_style),
            .chunk_index = i,
            .chunk_count = count,
            .payload = bytes[off..end],
        } };
        off = end;
    }
    return .{ .bytes = bytes, .messages = messages };
}

/// Join `chunks` (in order) and decode one terminal from them.
pub fn restore(
    alloc: Allocator,
    io: std.Io,
    chunks: []const []const u8,
    max_continuation_bytes: usize,
) snapshot.DecodeExactError!snapshot.Decoded {
    var total: usize = 0;
    for (chunks) |c| total += c.len;
    const bytes = try alloc.alloc(u8, total);
    defer alloc.free(bytes);
    var off: usize = 0;
    for (chunks) |c| {
        @memcpy(bytes[off..][0..c.len], c);
        off += c.len;
    }
    var reader: std.Io.Reader = .fixed(bytes);
    return try snapshot.decodeExact(alloc, io, &reader, .{
        .max_continuation_bytes = max_continuation_bytes,
    });
}

const Headless = @import("../terminal/headless_proto.zig").Headless;

fn feedAll(h: *Headless, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(off + 1024, bytes.len);
        h.feed(bytes[off..n]);
        off = n;
    }
}

test "daemon snapshot: deterministic screen round-trips through chunks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try Headless.init(alloc, 20, 10);
    defer h.deinit();
    // Deterministic content: styled text, cursor moves, and enough
    // lines to push rows into scrollback.
    feedAll(&h, "\x1b[1;31mred-bold\x1b[0m plain\r\n");
    feedAll(&h, "\x1b[3;5Hplaced");
    var i: u8 = 0;
    while (i < 14) : (i += 1) {
        var line: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "ln{d:0>2}\r\n", .{i});
        feedAll(&h, text);
    }

    var taken = try take(alloc, h.term, 42, 64); // tiny chunks: force many
    defer taken.deinit(alloc);
    try testing.expect(taken.messages.len > 1);
    try testing.expectEqual(taken.messages.len, taken.messages[0].snapshot.chunk_count);

    // Reassemble the payloads in order and restore.
    const payloads = try alloc.alloc([]const u8, taken.messages.len);
    defer alloc.free(payloads);
    for (taken.messages, 0..) |m, idx| {
        try testing.expectEqual(@as(u16, @intCast(idx)), m.snapshot.chunk_index);
        try testing.expectEqual(@as(u32, 42), m.snapshot.state_id);
        try testing.expectEqual(@as(u16, 20), m.snapshot.cols);
        try testing.expectEqual(@as(u16, 10), m.snapshot.rows);
        payloads[idx] = m.snapshot.payload;
    }
    var decoded = try restore(alloc, testing.io, payloads, 1024);
    defer decoded.deinit(alloc);
    var restored = decoded.toOwned();
    defer restored.deinit(alloc);

    // Grid, size, and cursor must be identical.
    try testing.expectEqual(h.term.cols, restored.cols);
    try testing.expectEqual(h.term.rows, restored.rows);
    var y: u16 = 0;
    while (y < 10) : (y += 1) {
        var x: u16 = 0;
        while (x < 20) : (x += 1) {
            try testing.expectEqual(
                gridCodepoint(h.term, x, y),
                gridCodepoint(&restored, x, y),
            );
        }
    }
    try testing.expectEqual(
        h.term.screens.active.cursor.x,
        restored.screens.active.cursor.x,
    );
    try testing.expectEqual(
        h.term.screens.active.cursor.y,
        restored.screens.active.cursor.y,
    );
}

/// Codepoint at (x, y) of a bare terminal (same read path as
/// `Headless.cellCodepoint`, without needing a stream).
fn gridCodepoint(term: *const Terminal, x: u16, y: u16) u21 {
    const cell = term.screens.active.pages
        .getCell(.{ .active = .{ .x = x, .y = y } }) orelse return 0;
    return switch (cell.cell.content_tag) {
        .codepoint, .codepoint_grapheme => cell.cell.content.codepoint.data,
        else => 0,
    };
}

test "daemon snapshot: codec frames carry chunks end to end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h = try Headless.init(alloc, 20, 10);
    defer h.deinit();
    feedAll(&h, "hello-chunks\r\nsecond line here\r\n");

    var taken = try take(alloc, h.term, 7, 32); // very tiny chunks
    defer taken.deinit(alloc);
    try testing.expect(taken.messages.len > 1);

    // Every message must survive a codec encode/decode round-trip.
    for (taken.messages) |m| {
        const enc = try codec.encode(alloc, m);
        defer alloc.free(enc);
        const back = try codec.decode(enc);
        const s = back.snapshot;
        try testing.expectEqual(m.snapshot.state_id, s.state_id);
        try testing.expectEqual(m.snapshot.chunk_index, s.chunk_index);
        try testing.expectEqual(m.snapshot.chunk_count, s.chunk_count);
        try testing.expectEqualSlices(u8, m.snapshot.payload, s.payload);
    }
}
