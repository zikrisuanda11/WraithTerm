//! Minimal native harness HUD (P2.9, D5).
//!
//! A programmatic GTK dialog (no .blp template, no gresource entry)
//! listing one row per daemon session with its merged Tier 1 + Tier 2
//! state. Data comes in as `harness_list.HarnessRow`s — the same
//! model the `+list-harnesses` CLI prints — so the dialog is a thin
//! native view over tested formatting logic.
//!
//! Runtime display is `[~]` headless (ADR-002); this file must at
//! least compile on the host and its pure helpers are unit-tested.
const std = @import("std");
const Allocator = std.mem.Allocator;
const gtk = @import("gtk");
const gobject = @import("gobject");
const hlist = @import("../../../daemon/harness_list.zig");

/// Dialog title.
pub const title = "WraithTerm Harnesses";

/// Pure row label: `id — verdict[(tool)]`. Unit-tested; the dialog
/// shows exactly this string per row.
pub fn rowLabel(row: *const hlist.HarnessRow, buf: []u8) []const u8 {
    const v = hlist.verdict(row);
    if (row.tool) |t| {
        return std.fmt.bufPrint(buf, "{s} — {s} ({s})", .{ row.id, v, t }) catch
            buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{s} — {s}", .{ row.id, v }) catch buf[0..0];
}

test "hud: row labels" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var row = hlist.HarnessRow{ .id = "deadbeef".*, .tier1 = .executing_tool, .tool = "edit", .tier2 = true };
    try testing.expectEqualStrings("deadbeef — executing_tool (edit)", rowLabel(&row, &buf));
    row = hlist.HarnessRow{ .id = "00000000".* };
    try testing.expectEqualStrings("00000000 — none", rowLabel(&row, &buf));
}

/// Present the dialog transient for `parent`. The dialog owns itself
/// (refSink; destroyed on window close).
pub fn present(
    parent: ?*gtk.Window,
    rows: []const hlist.HarnessRow,
) void {
    const win = gtk.Window.new();
    _ = win.as(gobject.Object).refSink();
    defer win.unref();
    win.as(gtk.Window).setTitle(title);
    if (parent) |p| win.as(gtk.Window).setTransientFor(p);
    win.as(gtk.Widget).setSizeRequest(420, 300);

    const list = gtk.ListBox.new();
    _ = list.as(gobject.Object).refSink();
    var added: usize = 0;
    for (rows) |*row| {
        var label_buf: [192]u8 = undefined;
        const text = rowLabel(row, &label_buf);
        // gtk.Label.new copies the string, so a stack Z-buffer works.
        var zbuf: [200]u8 = undefined;
        if (text.len + 1 > zbuf.len) continue;
        @memcpy(zbuf[0..text.len], text);
        zbuf[text.len] = 0;
        const label = gtk.Label.new(zbuf[0..text.len :0]);
        _ = label.as(gobject.Object).refSink();
        const item = gtk.ListBoxRow.new();
        _ = item.as(gobject.Object).refSink();
        item.setChild(label.as(gtk.Widget));
        list.append(item.as(gtk.Widget));
        added += 1;
    }
    if (added == 0) {
        const label = gtk.Label.new("No harness sessions (daemon unreachable or empty)");
        _ = label.as(gobject.Object).refSink();
        const item = gtk.ListBoxRow.new();
        _ = item.as(gobject.Object).refSink();
        item.setChild(label.as(gtk.Widget));
        list.append(item.as(gtk.Widget));
    }
    win.setChild(list.as(gtk.Widget));
    win.as(gtk.Window).present();
}
