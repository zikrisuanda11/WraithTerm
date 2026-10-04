//! omp bridge installer/uninstaller (P2.6, AC4.3).
//!
//! Installs the embedded bridge (`harness_bridge.source`) to
//! `<home>/.omp/agent/extensions/wraith-omp-bridge.ts` and removes it
//! on uninstall. Rules:
//! - Idempotent: install twice = same bytes, no dupes, no error.
//! - Never touches other users' extensions (only our filename).
//! - An existing foreign file at our path is backed up
//!   (`wraith-omp-bridge.ts.bak-<unix_ms>`) before overwrite, never
//!   destroyed.
//! - Uninstall removes only files carrying our marker; uninstall
//!   when absent is a no-op (exit 0).
//! - `home_dir` is passed in (tests use a temp HOME; production
//!   resolves via `os.homedir` at the CLI edge).
const std = @import("std");
const Allocator = std.mem.Allocator;
const bridge = @import("harness_bridge.zig");

/// Install dir relative to home.
pub const ext_rel_dir = ".omp/agent/extensions";
/// Installed filename.
pub const file_name = "wraith-omp-bridge.ts";

/// Result of an install: what happened, for CLI reporting.
pub const InstallOutcome = enum {
    installed,
    already_current,
    backed_up_and_installed,
};

/// Install the bridge under `home_dir`. Creates the extensions dir
/// (`0700`-ish: default umask applies, matching omp's own layout).
pub fn install(
    alloc: Allocator,
    io: std.Io,
    home_dir: []const u8,
) !InstallOutcome {
    const dir_path = try std.fs.path.join(alloc, &.{ home_dir, ext_rel_dir });
    defer alloc.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, file_name });
    defer alloc.free(file_path);

    // Already ours and current: nothing to do.
    if (readFile(alloc, io, file_path)) |cur| {
        defer alloc.free(cur);
        if (std.mem.eql(u8, cur, bridge.source)) return .already_current;
        // Foreign or stale: back it up, then overwrite.
        if (std.mem.indexOf(u8, cur, bridge.marker) == null) {
            try backupFile(alloc, io, file_path);
            try writeFile(io, file_path, bridge.source);
            return .backed_up_and_installed;
        }
        // Stale but ours: plain overwrite, no backup needed.
        try writeFile(io, file_path, bridge.source);
        return .installed;
    } else |_| {}

    try writeFile(io, file_path, bridge.source);
    return .installed;
}

/// Uninstall the bridge. Returns true when a file was removed.
pub fn uninstall(
    alloc: Allocator,
    io: std.Io,
    home_dir: []const u8,
) !bool {
    const file_path = try std.fs.path.join(
        alloc,
        &.{ home_dir, ext_rel_dir, file_name },
    );
    defer alloc.free(file_path);
    const cur = readFile(alloc, io, file_path) catch return false;
    defer alloc.free(cur);
    // Only remove files carrying our marker: never delete a foreign
    // file a user (or another tool) placed at our path.
    if (std.mem.indexOf(u8, cur, bridge.marker) == null) return false;
    std.Io.Dir.cwd().deleteFile(io, file_path) catch return false;
    return true;
}

fn readFile(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var buf: [8192]u8 = undefined;
    var r = f.reader(io, &buf);
    _ = r.interface.stream(&aw.writer, .unlimited) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [8192]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

fn backupFile(alloc: Allocator, io: std.Io, path: []const u8) !void {
    const now_ms: i64 = @intCast(@divFloor(
        std.Io.Timestamp.now(io, .real).toNanoseconds(),
        std.time.ns_per_ms,
    ));
    const bak = try std.fmt.allocPrint(alloc, "{s}.bak-{d}", .{ path, now_ms });
    defer alloc.free(bak);
    const data = try readFile(alloc, io, path);
    defer alloc.free(data);
    try writeFile(io, bak, data);
}

test "install: fresh, idempotent, foreign untouched" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var home = testing.tmpDir(.{});
    defer home.cleanup();
    const home_path = try home.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(home_path);

    // Fresh install.
    try testing.expectEqual(InstallOutcome.installed, try install(alloc, testing.io, home_path));
    // Second install is a no-op reporting current.
    try testing.expectEqual(InstallOutcome.already_current, try install(alloc, testing.io, home_path));
    // Installed bytes equal the embedded source.
    const file_path = try std.fs.path.join(alloc, &.{ home_path, ext_rel_dir, file_name });
    defer alloc.free(file_path);
    const cur = try readFile(alloc, testing.io, file_path);
    defer alloc.free(cur);
    try testing.expectEqualStrings(bridge.source, cur);

    // A neighbor extension is untouched by install.
    const neighbor = try std.fs.path.join(alloc, &.{ home_path, ext_rel_dir, "other.ts" });
    defer alloc.free(neighbor);
    try writeFile(testing.io, neighbor, "export default function(pi) { pi.on('x', () => {}); }");
    try testing.expectEqual(InstallOutcome.already_current, try install(alloc, testing.io, home_path));
    const kept = try readFile(alloc, testing.io, neighbor);
    defer alloc.free(kept);
    try testing.expectEqualStrings("export default function(pi) { pi.on('x', () => {}); }", kept);
}

test "install: foreign file backed up, uninstall marker-gated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var home = testing.tmpDir(.{});
    defer home.cleanup();
    const home_path = try home.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(home_path);

    // Plant a foreign file at our path.
    const dir_path = try std.fs.path.join(alloc, &.{ home_path, ext_rel_dir });
    defer alloc.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(testing.io, dir_path);
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, file_name });
    defer alloc.free(file_path);
    try writeFile(testing.io, file_path, "// someone else's extension\n");

    // Install backs it up instead of destroying it.
    try testing.expectEqual(
        InstallOutcome.backed_up_and_installed,
        try install(alloc, testing.io, home_path),
    );
    const cur = try readFile(alloc, testing.io, file_path);
    defer alloc.free(cur);
    try testing.expectEqualStrings(bridge.source, cur);

    // Uninstall removes ours (marker present).
    try testing.expect(try uninstall(alloc, testing.io, home_path));
    // Uninstall when absent is a silent no-op.
    try testing.expect(!try uninstall(alloc, testing.io, home_path));

    // A foreign file at our path is never deleted.
    try writeFile(testing.io, file_path, "// someone else's extension\n");
    try testing.expect(!try uninstall(alloc, testing.io, home_path));
    const kept = try readFile(alloc, testing.io, file_path);
    defer alloc.free(kept);
    try testing.expectEqualStrings("// someone else's extension\n", kept);
}
