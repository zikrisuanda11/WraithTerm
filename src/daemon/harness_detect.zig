//! Tier 2 harness process detector (P2.2).
//!
//! Pure function over a process-tree snapshot: given every visible
//! process (pid, ppid, argv[0] basename), decide whether a session's
//! child subtree runs a harness agent (omp, or a wrapper like `bun`
//! that re-execs it). The snapshot reader is platform-specific
//! (Linux `/proc` here; macOS `libproc` later) but the decision is
//! shared and fully unit-testable with fixtures.
//!
//! Linux-only reader in v1, like the rest of `src/daemon`.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// One process row of a snapshot.
pub const Proc = struct {
    pid: u32,
    ppid: u32,
    /// Basename of argv[0] (no directory, no NULs).
    comm: []const u8,
};

/// Basenames that count as the harness agent itself.
pub const harness_names = [_][]const u8{
    "omp",
    "pi-mono",
    "pi",
};

/// Wrapper runtimes whose child (same ppid chain) may be the real
/// agent: `bun x.js` re-execs into the harness, so a wrapper with a
/// harness-named descendant still counts.
pub const wrapper_names = [_][]const u8{
    "bun",
    "node",
    "deno",
};

fn isHarness(comm: []const u8) bool {
    for (harness_names) |h| {
        if (std.mem.eql(u8, comm, h)) return true;
    }
    return false;
}

fn isWrapper(comm: []const u8) bool {
    for (wrapper_names) |s| {
        if (std.mem.eql(u8, comm, s)) return true;
    }
    return false;
}

/// Does the subtree rooted at `root` (inclusive) contain a harness
/// process? `procs` is the whole snapshot; parent links resolve via
/// `ppid`. A harness nested under wrappers (any depth) counts; a
/// harness elsewhere in the snapshot does not.
pub fn subtreeHasHarness(procs: []const Proc, root: u32) bool {
    // Iterative DFS over (pid) with a small explicit stack; the
    // snapshot is flat so children are found by scanning ppid.
    var stack: [64]u32 = .{root} ++ .{0} ** 63;
    var top: usize = 1;
    // Guard against pid cycles from racy snapshots.
    var seen: [64]u32 = .{0} ** 64;
    var seen_n: usize = 0;

    while (top > 0) {
        top -= 1;
        const pid = stack[top];
        var dup = false;
        for (seen[0..seen_n]) |s| {
            if (s == pid) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_n < seen.len) {
            seen[seen_n] = pid;
            seen_n += 1;
        }
        for (procs) |p| {
            if (p.pid != pid) continue;
            if (isHarness(p.comm)) return true;
        }
        for (procs) |p| {
            if (p.ppid != pid) continue;
            if (top < stack.len) {
                stack[top] = p.pid;
                top += 1;
            }
        }
    }
    return false;
}

/// Basename of a path (after the last `/`), for argv[0] → comm.
pub fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

/// Read a Linux `/proc` snapshot. `root` scopes nothing (the whole
/// table is returned; callers pair it with `subtreeHasHarness`).
/// Unreadable processes (races, permissions) are skipped, never
/// fatal. `proc_dir` is `/proc` in production, a fixture dir in
/// tests.
pub fn readSnapshot(
    alloc: Allocator,
    io: std.Io,
    proc_dir: std.Io.Dir,
) ![]Proc {
    var out: std.ArrayList(Proc) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p.comm);
        out.deinit(alloc);
    }
    var it = proc_dir.iterate();
    while (it.next(io) catch null) |entry| {
        // NOTE: `/proc` entries may report a non-directory kind
        // (pseudo-filesystem), so gate on a numeric name instead.
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const comm = readComm(alloc, io, proc_dir, entry.name) orelse continue;
        errdefer alloc.free(comm);
        const ppid = readPpid(io, proc_dir, entry.name) orelse {
            alloc.free(comm);
            continue;
        };
        try out.append(alloc, .{ .pid = pid, .ppid = ppid, .comm = comm });
    }
    return out.toOwnedSlice(alloc);
}

/// argv[0] basename from `/proc/<pid>/cmdline`; falls back to the
/// `Name:` row of `status` when cmdline is empty (kernel threads).
/// Uses fixed-buffer `readFile`, never `readFileAlloc`: procfs files
/// report `st_size == 0`, so size-based allocation reads nothing.
fn readComm(
    alloc: Allocator,
    io: std.Io,
    proc_dir: std.Io.Dir,
    pid_dir: []const u8,
) ?[]u8 {
    var path_buf: [64]u8 = undefined;
    const cmd_path = std.fmt.bufPrint(&path_buf, "{s}/cmdline", .{pid_dir}) catch return null;
    // Only argv[0]'s head is needed; 8 KiB covers any sane path
    // (an argv[0] longer than that truncates, documented).
    var cmd_buf: [8192]u8 = undefined;
    const cmd = proc_dir.readFile(io, cmd_path, &cmd_buf) catch return null;
    if (cmd.len > 0) {
        const arg0 = std.mem.sliceTo(cmd, 0);
        if (arg0.len > 0) {
            return alloc.dupe(u8, basename(arg0)) catch return null;
        }
    }
    // Empty cmdline: kernel thread or zombie; use status Name:.
    const status_path = std.fmt.bufPrint(&path_buf, "{s}/status", .{pid_dir}) catch return null;
    var status_buf: [1024]u8 = undefined;
    const status = proc_dir.readFile(io, status_path, &status_buf) catch return null;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Name:")) {
            const name = std.mem.trim(u8, line["Name:".len..], " \t");
            if (name.len > 0) return alloc.dupe(u8, name) catch return null;
        }
    }
    return null;
}

/// Parent pid from `/proc/<pid>/stat` (field 4 after `(comm)`).
fn readPpid(io: std.Io, proc_dir: std.Io.Dir, pid_dir: []const u8) ?u32 {
    var path_buf: [64]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&path_buf, "{s}/stat", .{pid_dir}) catch return null;
    var buf: [1024]u8 = undefined;
    const stat = proc_dir.readFile(io, stat_path, &buf) catch return null;
    const rparen = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.splitScalar(u8, stat[rparen + 2 ..], ' ');
    // state(1) ppid(2) pgrp(3): ppid is the 2nd field after comm.
    _ = fields.next() orelse return null;
    const ppid_s = fields.next() orelse return null;
    return std.fmt.parseInt(u32, ppid_s, 10) catch null;
}

test "detect: direct omp child" {
    const procs = [_]Proc{
        .{ .pid = 100, .ppid = 1, .comm = "sh" },
        .{ .pid = 200, .ppid = 100, .comm = "omp" },
        .{ .pid = 300, .ppid = 1, .comm = "other" },
    };
    try std.testing.expect(subtreeHasHarness(&procs, 100));
    try std.testing.expect(!subtreeHasHarness(&procs, 300));
    try std.testing.expect(!subtreeHasHarness(&procs, 999));
}

test "detect: bun wrapper around omp" {
    const procs = [_]Proc{
        .{ .pid = 100, .ppid = 1, .comm = "sh" },
        .{ .pid = 200, .ppid = 100, .comm = "bun" },
        .{ .pid = 201, .ppid = 200, .comm = "omp" },
    };
    try std.testing.expect(isWrapper("bun"));
    try std.testing.expect(subtreeHasHarness(&procs, 100));
    try std.testing.expect(subtreeHasHarness(&procs, 200));
}

test "detect: wrapper without harness is clean" {
    const procs = [_]Proc{
        .{ .pid = 100, .ppid = 1, .comm = "sh" },
        .{ .pid = 200, .ppid = 100, .comm = "bun" },
        .{ .pid = 201, .ppid = 200, .comm = "esbuild" },
    };
    try std.testing.expect(!subtreeHasHarness(&procs, 100));
}

test "detect: sibling harness outside subtree ignored" {
    const procs = [_]Proc{
        .{ .pid = 100, .ppid = 1, .comm = "sh" },
        .{ .pid = 200, .ppid = 100, .comm = "vim" },
        .{ .pid = 300, .ppid = 1, .comm = "omp" },
    };
    try std.testing.expect(!subtreeHasHarness(&procs, 100));
    try std.testing.expect(subtreeHasHarness(&procs, 300));
}

test "detect: reads fixture proc dir" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Fixture: 100(sh) -> 200(bun) -> 201(omp); 300(vim) elsewhere.
    const rows = [_]struct { pid: []const u8, cmd: []const u8, ppid: u32 }{
        .{ .pid = "100", .cmd = "/bin/sh\x00-c\x00", .ppid = 1 },
        .{ .pid = "200", .cmd = "/home/u/.bun/bin/bun\x00run\x00", .ppid = 100 },
        .{ .pid = "201", .cmd = "omp\x00", .ppid = 200 },
        .{ .pid = "300", .cmd = "/usr/bin/vim\x00", .ppid = 1 },
    };
    for (rows) |r| {
        try tmp.dir.createDirPath(testing.io, r.pid);
        var dir = try tmp.dir.openDir(testing.io, r.pid, .{});
        defer dir.close(testing.io);
        try dir.writeFile(testing.io, .{ .sub_path = "cmdline", .data = r.cmd });
        var stat_buf: [256]u8 = undefined;
        const stat = try std.fmt.bufPrint(
            &stat_buf,
            "{s} ({s}) S {d} 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
            .{ r.pid, r.pid, r.ppid },
        );
        try dir.writeFile(testing.io, .{ .sub_path = "stat", .data = stat });
    }
    const procs = try readSnapshot(alloc, testing.io, tmp.dir);
    defer {
        for (procs) |p| alloc.free(p.comm);
        alloc.free(procs);
    }
    try testing.expectEqual(@as(usize, 4), procs.len);
    // Find pid 100 and check its subtree.
    var root: u32 = 0;
    for (procs) |p| {
        if (std.mem.eql(u8, p.comm, "sh")) root = p.pid;
    }
    try testing.expectEqual(@as(u32, 100), root);
    try testing.expect(subtreeHasHarness(procs, root));
    // bun must resolve to its basename, not the full path.
    for (procs) |p| {
        if (p.pid == 200) try testing.expectEqualStrings("bun", p.comm);
    }
}

test "detect: reads live /proc" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var root = std.Io.Dir.cwd().openDir(testing.io, "/proc", .{ .iterate = true }) catch
        return error.SkipZigTest;
    defer root.close(testing.io);
    const procs = try readSnapshot(alloc, testing.io, root);
    defer {
        for (procs) |p| alloc.free(p.comm);
        alloc.free(procs);
    }
    // The reader must see a non-empty table containing our own pid
    // with a sane comm/ppid. (Whether a harness runs here is
    // environment-dependent and NOT asserted.)
    try testing.expect(procs.len > 2);
    const self_pid: u32 = @intCast(linux.getpid());
    var found = false;
    for (procs) |p| {
        if (p.pid == self_pid and p.comm.len > 0) found = true;
    }
    try testing.expect(found);
}
