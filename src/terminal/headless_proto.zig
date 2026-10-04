//! WraithTerm Phase 0.3 prototype: drive a headless terminal.
//!
//! Proves the terminal core (`src/terminal/`) runs with no PTY, no GUI, no
//! renderer: feed VT bytes in, read the grid back. This is the foundation
//! the WraithTerm daemon builds on — the daemon owns this state and serves
//! snapshots/diffs to clients.
//!
//! Design note (found here, relevant to P1.4): `TerminalStream.Handler`
//! stores a `*Terminal`, so the terminal must live at a stable address for
//! the stream's whole lifetime. Moving a `Terminal` by value after
//! `Stream.init` would dangle that pointer. `Headless` therefore heap-
//! allocates the terminal and only ever hands out the pointer.
//!
//! Runs under `zig build test-lib-vt` (the `src/lib_vt.zig` test block
//! imports this file).

const std = @import("std");
const testing = std.testing;
const Terminal = @import("Terminal.zig");
const TerminalStream = @import("stream_terminal.zig").Stream;
const size = @import("size.zig");
const style = @import("style.zig");
const TinyIo = @import("../lib/TinyIo.zig");

/// A terminal driven entirely in-process, with no I/O attached.
pub const Headless = struct {
    alloc: std.mem.Allocator,
    term: *Terminal,
    stream: TerminalStream,

    pub fn init(
        alloc: std.mem.Allocator,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) !Headless {
        const term = try alloc.create(Terminal);
        errdefer alloc.destroy(term);
        term.* = try Terminal.init(TinyIo.init.io(), alloc, .{
            .cols = cols,
            .rows = rows,
        });
        errdefer term.deinit(alloc);

        const stream = TerminalStream.init(.{
            .allocator = alloc,
            .handler = .init(term),
            .continuation_max_bytes = 1024,
        });
        return .{ .alloc = alloc, .term = term, .stream = stream };
    }

    pub fn deinit(self: *Headless) void {
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.alloc.destroy(self.term);
    }

    /// Feed raw VT bytes (as would arrive from a PTY).
    pub fn feed(self: *Headless, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Codepoint at (x, y), or 0 for an empty/background-only cell.
    pub fn cellCodepoint(
        self: *Headless,
        x: size.CellCountInt,
        y: size.CellCountInt,
    ) u21 {
        const cell = self.term.screens.active.pages
            .getCell(.{ .active = .{ .x = x, .y = y } }) orelse return 0;
        return switch (cell.cell.content_tag) {
            .codepoint, .codepoint_grapheme => cell.cell.content.codepoint.data,
            else => 0,
        };
    }

    /// Style ID at (x, y). Zero means the default style.
    pub fn cellStyleId(
        self: *Headless,
        x: size.CellCountInt,
        y: size.CellCountInt,
    ) style.Id {
        const cell = self.term.screens.active.pages
            .getCell(.{ .active = .{ .x = x, .y = y } }) orelse return 0;
        return cell.cell.style_id;
    }

    pub fn cursorX(self: *Headless) size.CellCountInt {
        return self.term.screens.active.cursor.x;
    }

    pub fn cursorY(self: *Headless) size.CellCountInt {
        return self.term.screens.active.cursor.y;
    }
};

test "headless: feed plain text and read the grid" {
    const alloc = testing.allocator;
    var h = try Headless.init(alloc, 20, 4);
    defer h.deinit();

    h.feed("Hello");

    try testing.expectEqual(@as(u21, 'H'), h.cellCodepoint(0, 0));
    try testing.expectEqual(@as(u21, 'e'), h.cellCodepoint(1, 0));
    try testing.expectEqual(@as(u21, 'o'), h.cellCodepoint(4, 0));
    // Untouched cell is empty.
    try testing.expectEqual(@as(u21, 0), h.cellCodepoint(5, 0));
    // Cursor advanced past the text.
    try testing.expectEqual(@as(size.CellCountInt, 5), h.cursorX());
    try testing.expectEqual(@as(size.CellCountInt, 0), h.cursorY());
}

test "headless: SGR styling shows up on the cell" {
    const alloc = testing.allocator;
    var h = try Headless.init(alloc, 20, 4);
    defer h.deinit();

    h.feed("\x1b[31mR");
    // Red foreground means a non-default style ID.
    try testing.expect(h.cellStyleId(0, 0) != 0);
    try testing.expectEqual(@as(u21, 'R'), h.cellCodepoint(0, 0));
    // The next cell is not styled until text is written to it.
    h.feed("x");
    try testing.expectEqual(@as(u21, 'x'), h.cellCodepoint(1, 0));
}

test "headless: cursor addressing" {
    const alloc = testing.allocator;
    var h = try Headless.init(alloc, 20, 8);
    defer h.deinit();

    h.feed("\x1b[5;10HX"); // 1-based row 5, column 10
    try testing.expectEqual(@as(u21, 'X'), h.cellCodepoint(9, 4));
    // Cursor advanced one past the written cell.
    try testing.expectEqual(@as(size.CellCountInt, 10), h.cursorX());
    try testing.expectEqual(@as(size.CellCountInt, 4), h.cursorY());
}

test "headless: escape sequence split across feeds" {
    const alloc = testing.allocator;
    var h = try Headless.init(alloc, 20, 4);
    defer h.deinit();

    // The stream must hold partial sequences across write boundaries, as a
    // PTY freely splits them.
    h.feed("\x1b[");
    h.feed("3");
    h.feed("2mZ");
    try testing.expectEqual(@as(u21, 'Z'), h.cellCodepoint(0, 0));
    try testing.expect(h.cellStyleId(0, 0) != 0);
}

test "headless: alternate screen can be entered and left" {
    const alloc = testing.allocator;
    var h = try Headless.init(alloc, 20, 4);
    defer h.deinit();

    h.feed("main");
    try testing.expectEqual(@as(u21, 'm'), h.cellCodepoint(0, 0));

    h.feed("\x1b[?1049h");
    try testing.expectEqual(
        @as(@TypeOf(h.term.screens.active_key), .alternate),
        h.term.screens.active_key,
    );

    h.feed("\x1b[?1049l");
    try testing.expectEqual(
        @as(@TypeOf(h.term.screens.active_key), .primary),
        h.term.screens.active_key,
    );
    // Primary content survived the alt-screen round trip.
    try testing.expectEqual(@as(u21, 'm'), h.cellCodepoint(0, 0));
}

test "headless: resize preserves terminal usability" {
    const alloc = testing.allocator;
    var h = try Headless.init(alloc, 20, 4);
    defer h.deinit();

    h.feed("before");
    try h.term.resize(alloc, .{ .cols = 40, .rows = 10 });
    try testing.expectEqual(@as(size.CellCountInt, 40), h.term.cols);
    try testing.expectEqual(@as(size.CellCountInt, 10), h.term.rows);

    // The terminal still accepts input and writes to the (larger) grid.
    h.feed("\x1b[10;30Hend");
    try testing.expectEqual(@as(u21, 'e'), h.cellCodepoint(29, 9));
}
