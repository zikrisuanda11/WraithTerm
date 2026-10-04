//! Daemon control socket: Unix listener with locked-down file modes
//! (P1.6, D8).
//!
//! Layout: `$XDG_RUNTIME_DIR/wraith/<user>.sock` (fallback
//! `$TMPDIR/wraith-<uid>/control.sock`), directory `0700`, socket
//! `0600`. Only the owning user can connect; no auth tokens needed
//! on the local socket.
//!
//! Linux-only in v1 (raw `std.os.linux` syscalls, the same layer the
//! PTY and process code already uses). Other platforms get a
//! compile error until someone ports this module.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const dir_mode: linux.mode_t = 0o700;
pub const socket_mode: linux.mode_t = 0o600;

/// Resolve the control socket path. Caller owns the returned slice.
/// Uses `XDG_RUNTIME_DIR` when set, else `$TMPDIR` (else `/tmp`).
/// `environ` is passed in (repo pattern: libs never read globals).
pub fn socketPath(alloc: Allocator, environ: std.process.Environ) Allocator.Error![]u8 {
    const user = environ.getPosix("USER") orelse "user";
    if (environ.getPosix("XDG_RUNTIME_DIR")) |run| {
        return std.fmt.allocPrint(alloc, "{s}/wraith/{s}.sock", .{ run, user });
    }
    const tmp = environ.getPosix("TMPDIR") orelse "/tmp";
    return std.fmt.allocPrint(alloc, "{s}/wraith-{d}/control.sock", .{ tmp, linux.getuid() });
}

pub const ListenError = Allocator.Error || error{
    PathTooLong,
    MkdirFailed,
    ChmodFailed,
    SocketFailed,
    BindFailed,
    ListenFailed,
};

pub const Server = struct {
    fd: linux.socket_t,
    path: []u8,
    alloc: Allocator,

    /// Bind + listen on `path`. Creates the parent dir (`0700`), removes
    /// any stale socket file, and chmods the bound socket to `0600`
    /// (bind honors umask, so an explicit chmod is required).
    pub fn listen(alloc: Allocator, path: []const u8) ListenError!Server {
        // Parent dir with locked mode (mkdir honors umask too).
        const dir = std.fs.path.dirname(path) orelse return error.MkdirFailed;
        const dir_z = try alloc.dupeZ(u8, dir);
        defer alloc.free(dir_z);
        makeDir(dir_z) catch return error.MkdirFailed;
        chmodPath(dir_z, dir_mode) catch return error.ChmodFailed;

        const fd: linux.socket_t = syscall(linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
            0,
        )) catch return error.SocketFailed;
        errdefer _ = linux.close(fd);

        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        const addr_len: linux.socklen_t = @intCast(
            @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
        );

        // Drop a stale socket from a dead daemon; a live one would hold
        // the path busy and bind would fail instead.
        const path_z = try alloc.dupeZ(u8, path);
        defer alloc.free(path_z);
        _ = linux.unlink(path_z);

        _ = syscall(linux.bind(fd, @ptrCast(&addr), addr_len)) catch
            return error.BindFailed;
        // chmod by path: fchmod on a socket fd is a silent no-op on
        // Linux, but chmod on the path sets the socket inode mode.
        chmodPath(path_z, socket_mode) catch return error.ChmodFailed;
        _ = syscall(linux.listen(fd, 16)) catch return error.ListenFailed;

        return .{ .fd = fd, .path = try alloc.dupe(u8, path), .alloc = alloc };
    }

    pub fn deinit(self: *Server) void {
        _ = linux.close(self.fd);
        const z = self.alloc.dupeZ(u8, self.path) catch return;
        defer self.alloc.free(z);
        _ = linux.unlink(z);
        self.alloc.free(self.path);
    }
};

fn makeDir(path_z: [*:0]const u8) !void {
    switch (errno(linux.mkdir(path_z, dir_mode))) {
        .SUCCESS, .EXIST => {},
        else => return error.MkdirFailed,
    }
}

fn chmodPath(path_z: [*:0]const u8, mode: linux.mode_t) !void {
    switch (errno(linux.chmod(path_z, mode))) {
        .SUCCESS => {},
        else => return error.ChmodFailed,
    }
}

fn chmodFd(fd: linux.socket_t, mode: linux.mode_t) !void {
    switch (errno(linux.fchmod(fd, mode))) {
        .SUCCESS => {},
        else => return error.ChmodFailed,
    }
}

fn syscall(rc: usize) error{Failed}!linux.socket_t {
    return switch (errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => error.Failed,
    };
}

/// Same as `syscall`, for the syscalls that return `i32`.
fn syscallFd(rc: i32) error{Failed}!linux.socket_t {
    return if (rc < 0) error.Failed else rc;
}

fn errno(rc: usize) linux.E {
    const signed: isize = @bitCast(rc);
    return if (signed < 0 and signed >= -4095)
        @enumFromInt(-signed)
    else
        .SUCCESS;
}

test "daemon socket: dir 0700, socket 0600, accept works" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    // Isolated dir under TMPDIR: never touch the real runtime path.
    const tmp = testing.environ.getPosix("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(alloc, "{s}/wraith-socktest-{d}", .{ tmp, linux.getpid() });
    defer alloc.free(dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/ctl.sock", .{dir});
    defer alloc.free(path);

    var server = try Server.listen(alloc, path);
    defer {
        server.deinit();
        // Socket file must be gone after deinit.
        testing.expectError(error.StatFailed, modeOf(alloc, path)) catch {};
    }

    // Modes via statx (no std.fs dependency in the daemon).
    try testing.expectEqual(@as(u16, 0o700), (try modeOf(alloc, dir)) & 0o777);
    try testing.expectEqual(@as(u16, 0o600), (try modeOf(alloc, path)) & 0o777);

    // A client can connect and the server accepts + exchanges a byte.
    const cfd: linux.socket_t = try syscall(linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    ));
    defer _ = linux.close(cfd);
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    _ = try syscall(linux.connect(
        cfd,
        @ptrCast(&addr),
        @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1),
    ));
    const afd: linux.socket_t = try syscall(linux.accept(server.fd, null, null));
    defer _ = linux.close(afd);

    const w = linux.write(cfd, "Q", 1);
    try testing.expectEqual(@as(usize, 1), @as(usize, @bitCast(w)));
    var b: [1]u8 = undefined;
    const r = linux.read(afd, &b, 1);
    try testing.expectEqual(@as(usize, 1), @as(usize, @bitCast(r)));
    try testing.expectEqual(@as(u8, 'Q'), b[0]);
}

fn modeOf(alloc: Allocator, path: []const u8) !u16 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    var stx: linux.Statx = undefined;
    switch (errno(linux.statx(
        linux.AT.FDCWD,
        z,
        0,
        .{ .MODE = true },
        &stx,
    ))) {
        .SUCCESS => return stx.mode,
        else => return error.StatFailed,
    }
}
