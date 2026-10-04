//! Managed image-paste store (P3.1, D1).
//!
//! Pasted images land in `$XDG_CACHE_HOME/wraith/paste/` (macOS:
//! `~/Library/Caches/wraith/paste/`), named
//! `paste-<unix_ms>-<rand6>.<ext>`, files `0600`, dir `0700`.
//! Lifecycle enforced by `prune` (call at start + hourly):
//! files older than 24 h go, then oldest-first until the dir fits
//! 200 MiB. Single images over 25 MiB are refused at `store`.
//!
//! Pure over caller-provided dirs (tests use temp dirs); platform
//! cache resolution stays at the call edge (`os.xdg`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Max single image: 25 MiB (D1).
pub const max_image_bytes: usize = 25 * 1024 * 1024;
/// Dir quota: 200 MiB (D1).
pub const max_dir_bytes: usize = 200 * 1024 * 1024;
/// TTL: 24 h in nanoseconds (D1).
pub const ttl_ns: u64 = 24 * std.time.ns_per_hour;
/// Paste subdir under the platform cache home.
pub const paste_subdir = "wraith/paste";

/// Supported image kinds (by magic bytes, not extension).
pub const Kind = enum {
    png,
    jpeg,

    pub fn extension(self: Kind) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
        };
    }
};

/// Sniff PNG (`89 50 4E 47 …`) or JPEG (`FF D8 FF`) magic.
pub fn sniffKind(data: []const u8) ?Kind {
    if (data.len >= 8 and
        data[0] == 0x89 and data[1] == 0x50 and
        data[2] == 0x4E and data[3] == 0x47) return .png;
    if (data.len >= 3 and
        data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) return .jpeg;
    return null;
}

/// Store one image under `dir` (created `0700` when missing).
/// Returns the owned absolute path. Refuses oversize/unknown data.
pub fn store(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    now_ms: i64,
    rand6: []const u8,
    data: []const u8,
) ![]u8 {
    if (data.len > max_image_bytes) return error.TooLarge;
    const kind = sniffKind(data) orelse return error.UnknownImage;
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "paste-{d}-{s}.{s}",
        .{ now_ms, rand6, kind.extension() },
    );
    const path = try std.fs.path.join(alloc, &.{ dir_path, name });
    errdefer alloc.free(path);
    var f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    var buf: [8192]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
    // Files 0600 regardless of umask (D1).
    f.setPermissions(io, .fromMode(0o600)) catch {};
    return path;
}

/// Prune `dir`: drop files older than 24 h (by mtime), then
/// oldest-first until the total fits the quota. Unknown files are
/// left alone (only `paste-*` managed). Returns removals.
pub fn prune(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    now_ns: u64,
) !usize {
    return pruneWith(alloc, io, dir, now_ns, ttl_ns, max_dir_bytes);
}

/// `prune` with explicit TTL/quota (tests shrink them; production
/// passes the D1 constants via `prune`).
pub fn pruneWith(
    alloc: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    now_ns: u64,
    ttl: u64,
    quota_bytes: u64,
) !usize {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(alloc);
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "paste-")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const size = stat.size;
        const mtime_ns: u64 = @intCast(@max(stat.mtime.toNanoseconds(), 0));
        total += size;
        try entries.append(alloc, .{
            .name = try alloc.dupe(u8, entry.name),
            .size = size,
            .mtime_ns = mtime_ns,
        });
    }
    defer {
        for (entries.items) |e| alloc.free(e.name);
    }
    var removed: usize = 0;
    // Pass 1: TTL.
    for (entries.items) |*e| {
        if (now_ns >= e.mtime_ns and now_ns - e.mtime_ns > ttl) {
            dir.deleteFile(io, e.name) catch continue;
            total -= @min(total, e.size);
            removed += 1;
            e.gone = true;
        }
    }
    // Pass 2: quota, oldest first.
    if (total > quota_bytes) {
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.mtime_ns < b.mtime_ns;
            }
        }.lessThan);
        for (entries.items) |*e| {
            if (total <= quota_bytes) break;
            if (e.gone) continue;
            dir.deleteFile(io, e.name) catch continue;
            total -= @min(total, e.size);
            removed += 1;
            e.gone = true;
        }
    }
    return removed;
}

const Entry = struct {
    name: []u8,
    size: u64,
    mtime_ns: u64,
    gone: bool = false,
};

test "store: names, perms, sniffing, limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A } ++ [_]u8{0} ** 100;
    const path = try store(alloc, testing.io, tmp.dir, ".", 1700000000000, "a1b2c3", &png);
    defer alloc.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "paste-1700000000000-a1b2c3.png"));

    // Mode 0600.
    {
        var f = try tmp.dir.openFile(testing.io, "paste-1700000000000-a1b2c3.png", .{});
        defer f.close(testing.io);
        const st = try f.stat(testing.io);
        try testing.expectEqual(@as(u16, 0o600), st.permissions.toMode() & 0o777);
    }
    // JPEG sniffs to .jpg.
    const jpg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 } ++ [_]u8{0} ** 50;
    const jpath = try store(alloc, testing.io, tmp.dir, ".", 1700000000001, "d4e5f6", &jpg);
    defer alloc.free(jpath);
    try testing.expect(std.mem.endsWith(u8, jpath, ".jpg"));
    // Unknown magic refused.
    try testing.expectError(error.UnknownImage, store(alloc, testing.io, tmp.dir, ".", 1, "x", "hello"));
    // Oversize refused.
    var big: [64]u8 = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A } ++ .{0} ** 56;
    _ = &big;
    try testing.expectError(error.TooLarge, store(alloc, testing.io, tmp.dir, ".", 1, "x", "-" ** (max_image_bytes + 1)));
}

test "prune: ttl then quota, strangers kept" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Real clock: files are born "now", so TTL math is honest.
    const now_ns: u64 = @intCast(@max(
        std.Io.Timestamp.now(testing.io, .real).toNanoseconds(),
        0,
    ));

    const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A } ++ [_]u8{1} ** 32;
    const p1 = try store(alloc, testing.io, tmp.dir, ".", 1, "aaaaaa", &png);
    defer alloc.free(p1);
    // Stranger file: never managed, never removed.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "keep me" });

    // Fresh file: nothing expires, quota far away.
    try testing.expectEqual(@as(usize, 0), try prune(alloc, testing.io, tmp.dir, now_ns));
    // 30 days later: the paste expires, the stranger stays.
    try testing.expectEqual(@as(usize, 1), try prune(alloc, testing.io, tmp.dir, now_ns + 30 * std.time.ns_per_day));
    // Stranger survived.
    {
        var f = try tmp.dir.openFile(testing.io, "notes.txt", .{});
        defer f.close(testing.io);
    }
}

test "prune: quota drops oldest first" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const now_ns: u64 = @intCast(@max(
        std.Io.Timestamp.now(testing.io, .real).toNanoseconds(),
        0,
    ));
    // Three 100-byte pastes; quota 250 forces exactly one eviction,
    // and a second prune is clean.
    const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A } ++ [_]u8{1} ** 92;
    var paths: [3][]u8 = undefined;
    for (&paths, 0..) |*p, i| {
        var rand: [8]u8 = undefined;
        const tag = try std.fmt.bufPrint(&rand, "q{d:0>6}", .{i});
        p.* = try store(alloc, testing.io, tmp.dir, ".", 1, tag, &png);
    }
    defer for (paths) |p| alloc.free(p);
    try testing.expectEqual(@as(usize, 1), try pruneWith(alloc, testing.io, tmp.dir, now_ns, ttl_ns, 250));
    try testing.expectEqual(@as(usize, 0), try pruneWith(alloc, testing.io, tmp.dir, now_ns, ttl_ns, 250));
}
