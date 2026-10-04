//! `--list-harnesses` model (P2.7, D5/D6).
//!
//! Merges Tier 1 (per-session bridge state from `HarnessState`) and
//! Tier 2 (process-tree detection from `harness_detect`) into one row
//! per session, then renders text or JSON. Pure over caller-provided
//! rows: the daemon fills `HarnessRow`s from live state, the CLI
//! prints them. JSON is hand-rolled (fixed schema, no escapes
//! needed: ids are hex, states/tools come from fixed vocabularies —
//! tool names are sanitized to `[A-Za-z0-9_-]` at format time).
const std = @import("std");
const Allocator = std.mem.Allocator;
const hevent = @import("harness_event.zig");

/// One session's merged harness view.
pub const HarnessRow = struct {
    /// 8-char hex session id.
    id: [8]u8,
    /// Tier 1 bridge state (`unknown` when no event yet).
    tier1: hevent.State = .unknown,
    /// Tier 1 tool name (null when none reported).
    tool: ?[]const u8 = null,
    /// Tier 2 process-tree detection.
    tier2: bool = false,
};

/// Combined verdict: Tier 1 wins when it has reported; Tier 2 is the
/// fallback signal; neither means no harness evidence.
pub fn verdict(row: *const HarnessRow) []const u8 {
    if (row.tier1 != .unknown) return @tagName(row.tier1);
    if (row.tier2) return "detected";
    return "none";
}

fn stateName(s: hevent.State) []const u8 {
    return @tagName(s);
}

/// Sanitize a tool name to the JSON-safe vocabulary. Returns the
/// prefix that fits in `buf` (truncated, never escaped).
fn cleanTool(tool: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (tool) |c| {
        if (n >= buf.len) break;
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Render rows as text: `id tier1[/tool] tier2 verdict`, one per line.
pub fn formatText(alloc: Allocator, rows: []const HarnessRow) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (rows) |*row| {
        if (row.tool) |t| {
            var tbuf: [64]u8 = undefined;
            try w.print("{s} {s}/{s} tier2={} {s}\n", .{
                row.id,
                stateName(row.tier1),
                cleanTool(t, &tbuf),
                row.tier2,
                verdict(row),
            });
        } else {
            try w.print("{s} {s} tier2={} {s}\n", .{
                row.id,
                stateName(row.tier1),
                row.tier2,
                verdict(row),
            });
        }
    }
    return out.toOwnedSlice();
}

/// Render rows as a JSON array (D5: feeds the future native HUD).
/// Schema: `[{"id":"…","tier1":"…","tool":"…|null",
/// "tier2":bool,"verdict":"…"}]`.
pub fn formatJson(alloc: Allocator, rows: []const HarnessRow) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("[");
    for (rows, 0..) |*row, i| {
        if (i > 0) try w.writeAll(",");
        var tbuf: [64]u8 = undefined;
        const tool = if (row.tool) |t| cleanTool(t, &tbuf) else "";
        try w.print(
            "{{\"id\":\"{s}\",\"tier1\":\"{s}\",\"tool\":\"{s}\",\"tier2\":{},\"verdict\":\"{s}\"}}",
            .{
                row.id,
                stateName(row.tier1),
                tool,
                row.tier2,
                verdict(row),
            },
        );
    }
    try w.writeAll("]\n");
    return out.toOwnedSlice();
}

test "harnesses: verdict prefers tier1, falls back to tier2" {
    const testing = std.testing;
    var row = HarnessRow{ .id = "deadbeef".*, .tier1 = .unknown, .tier2 = true };
    try testing.expectEqualStrings("detected", verdict(&row));
    row.tier1 = .idle;
    try testing.expectEqualStrings("idle", verdict(&row));
    row.tier1 = .executing_tool;
    row.tier2 = false;
    try testing.expectEqualStrings("executing_tool", verdict(&row));
    row = HarnessRow{ .id = "deadbeef".* };
    try testing.expectEqualStrings("none", verdict(&row));
}

test "harnesses: text and JSON snapshot" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const rows = [_]HarnessRow{
        .{ .id = "deadbeef".*, .tier1 = .executing_tool, .tool = "edit", .tier2 = true },
        .{ .id = "00000000".*, .tier1 = .unknown, .tier2 = false },
        .{ .id = "cafef00d".*, .tier1 = .awaiting_approval, .tool = "ask user", .tier2 = true },
    };
    const text = try formatText(alloc, &rows);
    defer alloc.free(text);
    try testing.expectEqualStrings(
        \\deadbeef executing_tool/edit tier2=true executing_tool
        \\00000000 unknown tier2=false none
        \\cafef00d awaiting_approval/askuser tier2=true awaiting_approval
        \\
    , text);
    const json = try formatJson(alloc, &rows);
    defer alloc.free(json);
    try testing.expectEqualStrings(
        \\[{"id":"deadbeef","tier1":"executing_tool","tool":"edit","tier2":true,"verdict":"executing_tool"},{"id":"00000000","tier1":"unknown","tool":"","tier2":false,"verdict":"none"},{"id":"cafef00d","tier1":"awaiting_approval","tool":"askuser","tier2":true,"verdict":"awaiting_approval"}]
        \\
    , json);
    // Empty set renders empty (never null).
    const empty_text = try formatText(alloc, &.{});
    defer alloc.free(empty_text);
    try testing.expectEqualStrings("", empty_text);
    const empty_json = try formatJson(alloc, &.{});
    defer alloc.free(empty_json);
    try testing.expectEqualStrings("[]\n", empty_json);
}
