//! OS notification on `awaiting_approval` (P2.8).
//!
//! Pure edge trigger (`shouldNotify`) plus a per-platform shim
//! runner that fails silently: the daemon must never stall or crash
//! because a desktop notification could not be delivered (no display,
//! no bus, missing helper). Actual on-screen delivery is `[~]` in
//! headless environments (ADR-002); the trigger logic is unit-tested
//! and the shim spawn is fire-and-forget.
//!
//! Linux-only runner in v1 (notify-send); macOS (osascript) is
//! compile-gated for later.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const hevent = @import("harness_event.zig");

/// Fire only on the edge INTO `awaiting_approval`: repeated reports
/// of the same state must not re-notify, and leaving the state
/// re-arms the trigger.
pub fn shouldNotify(prev: hevent.State, next: hevent.State) bool {
    return prev != .awaiting_approval and next == .awaiting_approval;
}

/// Human-readable title/body for the shim. `tool` omits when null;
/// the session id is always included so the user knows which
/// session needs them.
pub fn message(
    session_id: []const u8,
    tool: ?[]const u8,
    title_buf: []u8,
    body_buf: []u8,
) struct { title: []const u8, body: []const u8 } {
    const title = std.fmt.bufPrint(title_buf, "WraithTerm: approval needed", .{}) catch
        title_buf[0..0];
    const body = if (tool) |t|
        std.fmt.bufPrint(body_buf, "Session {s} awaits approval ({s})", .{ session_id, t }) catch
            body_buf[0..0]
    else
        std.fmt.bufPrint(body_buf, "Session {s} awaits approval", .{session_id}) catch
            body_buf[0..0];
    return .{ .title = title, .body = body };
}

/// Best-effort OS notification. Never fails: every error (missing
/// helper, no display, spawn failure) is swallowed. The child is
/// detached (never waited on) so the daemon loop cannot block.
pub fn send(io: std.Io, alloc: Allocator, title: []const u8, body: []const u8) void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.process.spawn(io, .{
            .argv = &.{ "notify-send", "-a", "WraithTerm", title, body },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
    } else if (comptime builtin.os.tag == .macos) {
        var script_buf: [512]u8 = undefined;
        const script = std.fmt.bufPrint(
            &script_buf,
            "display notification \"{s}\" with title \"{s}\"",
            .{ body, title },
        ) catch return;
        _ = std.process.spawn(io, .{
            .argv = &.{ "osascript", "-e", script },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
    }
    _ = alloc;
}

test "notify: fires only on entry edge" {
    const testing = std.testing;
    try testing.expect(shouldNotify(.thinking, .awaiting_approval));
    try testing.expect(shouldNotify(.executing_tool, .awaiting_approval));
    try testing.expect(shouldNotify(.idle, .awaiting_approval));
    try testing.expect(shouldNotify(.unknown, .awaiting_approval));
    // Repeated reports do not re-fire.
    try testing.expect(!shouldNotify(.awaiting_approval, .awaiting_approval));
    // Leaving the state never fires (and re-arms the next entry).
    try testing.expect(!shouldNotify(.awaiting_approval, .thinking));
    try testing.expect(!shouldNotify(.awaiting_approval, .idle));
    try testing.expect(!shouldNotify(.thinking, .executing_tool));
    try testing.expect(!shouldNotify(.idle, .idle));
}

test "notify: message carries session and tool" {
    const testing = std.testing;
    var title_buf: [128]u8 = undefined;
    var body_buf: [256]u8 = undefined;
    const m = message("deadbeef", "edit", &title_buf, &body_buf);
    try testing.expectEqualStrings("WraithTerm: approval needed", m.title);
    try testing.expectEqualStrings("Session deadbeef awaits approval (edit)", m.body);
    const m2 = message("deadbeef", null, &title_buf, &body_buf);
    try testing.expectEqualStrings("Session deadbeef awaits approval", m2.body);
}

test "notify: send never fails without a display" {
    // No assertion on delivery ([~] headless): this only proves the
    // shim path cannot raise, crash, or block the caller even with
    // no desktop session present.
    const testing = std.testing;
    send(testing.io, testing.allocator, "WraithTerm: approval needed", "Session x awaits approval");
}
