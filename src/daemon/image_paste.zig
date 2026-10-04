//! Image-path paste delivery (P3.2, D1).
//!
//! When an image paste is detected, the stored file's absolute path
//! is shell-quoted and delivered to the PTY as a bracketed paste
//! (mode 2004 framing via `input.paste.encode` — the same function
//! every text paste uses, so plain-text pasting is provably
//! unchanged per AC3.3). Only the path travels the wire; the image
//! bytes never do (local v1).
//!
//! `deliverImage` is the D1 hook: v1 implements `.path` only; OSC/APC
//! and preview modes stay unimplemented by design.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input_paste = @import("../input/paste.zig");

/// Delivery mode (D1: only `path` in v1).
pub const Mode = enum {
    path,
};

/// Shell-quote `path` for POSIX shells (D1): bare when it contains
/// only safe chars, otherwise single-quoted with embedded quotes as
/// `'\''`. Never emits escapes the shell would reinterpret.
pub fn quoteShell(path: []const u8, out: *std.ArrayList(u8), alloc: Allocator) !void {
    var safe = path.len > 0;
    for (path) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            switch (c) {
                '/', '_', '-', '.', ',', ':', '+', '@', '%', '=', '~' => true,
                else => false,
            };
        if (!ok) {
            safe = false;
            break;
        }
    }
    if (safe) {
        try out.appendSlice(alloc, path);
        return;
    }
    try out.append(alloc, '\'');
    for (path) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
}

/// D1 hook: deliver an image to the PTY. V1 only supports `.path`
/// (quoted absolute path, bracketed per `bracketed`). Returns the
/// owned bytes to write. Text input never flows through here — it
/// keeps calling `input.paste.encode` directly (AC3.3).
pub fn deliverImage(
    alloc: Allocator,
    mode: Mode,
    path: []const u8,
    bracketed: bool,
) ![]u8 {
    switch (mode) {
        .path => {
            var quoted: std.ArrayList(u8) = .empty;
            defer quoted.deinit(alloc);
            try quoteShell(path, &quoted, alloc);
            // encode() may need to strip control bytes in place, so
            // hand it a mutable copy (paths are trusted store output,
            // but a weird filename must not break the call).
            const mut = try alloc.dupe(u8, quoted.items);
            defer alloc.free(mut);
            const parts = input_paste.encode(mut, .{ .bracketed = bracketed });
            var total: usize = 0;
            for (parts) |p| total += p.len;
            const out = try alloc.alloc(u8, total);
            errdefer alloc.free(out);
            var off: usize = 0;
            for (parts) |p| {
                @memcpy(out[off..][0..p.len], p);
                off += p.len;
            }
            return out;
        },
    }
}

test "quote: safe paths bare, hostile paths quoted" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "/tmp/wraith/paste/paste-1-a1b2c3.png", .out = "/tmp/wraith/paste/paste-1-a1b2c3.png" },
        .{ .in = "/tmp/my pics/shot 1.png", .out = "'/tmp/my pics/shot 1.png'" },
        .{ .in = "/tmp/o'clock.png", .out = "'/tmp/o'\\''clock.png'" },
        .{ .in = "/tmp/$(rm -rf ~).png", .out = "'/tmp/$(rm -rf ~).png'" },
        .{ .in = "/tmp/a`b`.png", .out = "'/tmp/a`b`.png'" },
        .{ .in = "/tmp/a;b&c|d.png", .out = "'/tmp/a;b&c|d.png'" },
        .{ .in = "/tmp/ünïcode-日本語.png", .out = "'/tmp/ünïcode-日本語.png'" },
        .{ .in = "/tmp/dollar$home.png", .out = "'/tmp/dollar$home.png'" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try quoteShell(c.in, &out, alloc);
        try testing.expectEqualStrings(c.out, out.items);
    }
}

test "deliver: bracketed path framed, unbracketed plain" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const path = "/tmp/wraith/paste/paste-1-a1b2c3.png";
    const framed = try deliverImage(alloc, .path, path, true);
    defer alloc.free(framed);
    try testing.expect(std.mem.startsWith(u8, framed, input_paste.bracketed_prefix));
    try testing.expect(std.mem.endsWith(u8, framed, input_paste.bracketed_suffix));
    try testing.expect(std.mem.indexOf(u8, framed, path) != null);
    const plain = try deliverImage(alloc, .path, path, false);
    defer alloc.free(plain);
    try testing.expectEqualStrings(path, plain);
    // Hostile names stay one shell token inside the frame.
    const evil = try deliverImage(alloc, .path, "/tmp/a b'x.png", true);
    defer alloc.free(evil);
    try testing.expect(std.mem.indexOf(u8, evil, "'/tmp/a b'\\''x.png'") != null);
}

test "deliver: plain text path unaffected (AC3.3)" {
    // The text-paste pipeline calls `input.paste.encode` directly
    // and never touches this module. This proves that for a path
    // needing no quoting, `deliverImage` adds nothing beyond what
    // `encode` itself does (quoting is the identity there).
    const testing = std.testing;
    const alloc = testing.allocator;
    const text = "helloworld.png";
    const via_deliver = try deliverImage(alloc, .path, text, true);
    defer alloc.free(via_deliver);
    const mut = try alloc.dupe(u8, text);
    defer alloc.free(mut);
    const parts = input_paste.encode(mut, .{ .bracketed = true });
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(alloc);
    for (parts) |p| try expect.appendSlice(alloc, p);
    try testing.expectEqualStrings(expect.items, via_deliver);
}
