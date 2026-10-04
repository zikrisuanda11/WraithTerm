//! Daemon-owned PTY + child + headless terminal state (P1.4).
//!
//! `DaemonPty` is the unit of "one running session" on the daemon side:
//! it owns the PTY master fd, the child pid, and the headless `Terminal`
//! fed from PTY output (ADR-004). Client input is written to the master;
//! output is pumped into the terminal; resize updates both.
//!
//! Detach safety (AC1.1) is structural: detaching a client only flips
//! `Session.state` in the session manager. Nothing here runs on detach —
//! no stop, no SIGHUP, no fd close. The child only dies when the session
//! is explicitly killed (`kill()`) or the daemon exits.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const Pty = @import("../pty.zig").Pty;
const Command = @import("../Command.zig");
const Headless = @import("../terminal/headless_proto.zig").Headless;

pub const Error = Allocator.Error ||
    Pty.Error ||
    error{
        SpawnFailed,
        ExecFailedInChild,
        ResizeFailed,
    };

pub const DaemonPty = struct {
    alloc: Allocator,
    /// Heap-boxed so the pre-exec callback always sees a stable address
    /// even if this struct moves.
    pty: *Pty,
    pid: posix.pid_t,
    master: Pty.Fd,
    headless: Headless,
    exited: bool = false,

    fn preExec(cmd: *Command) ?u8 {
        const pty = cmd.getData(Pty) orelse return 1;
        pty.childPreExec() catch return 1;
        return null;
    }

    /// Spawn `argv[0]` with `argv` on a fresh PTY of `cols`x`rows`.
    /// `env` is inherited from this process when null.
    pub fn spawn(
        alloc: Allocator,
        argv: []const [:0]const u8,
        env: ?*const std.process.Environ.Map,
        cols: u16,
        rows: u16,
    ) Error!*DaemonPty {
        if (comptime builtin.os.tag == .windows) @compileError("wraith daemon pty: windows unsupported in v1");
        const self = try alloc.create(DaemonPty);
        errdefer alloc.destroy(self);
        const pty = try alloc.create(Pty);
        errdefer alloc.destroy(pty);
        pty.* = try Pty.open(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        });
        errdefer pty.deinit();

        var cmd: Command = .{
            .path = argv[0],
            .args = argv,
            .env = env,
            .stdin = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
            .stdout = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
            .stderr = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
            .os_pre_exec = preExec,
            .rt_pre_exec = null,
            // Never read: both apprt hooks above are null, and the daemon
            // must not depend on GTK config types. If a hook is ever set,
            // its info struct must be filled in for real instead.
            .rt_pre_exec_info = std.mem.zeroes(Command.RtPreExecInfo),
            .rt_post_fork = null,
            .rt_post_fork_info = std.mem.zeroes(Command.RtPostForkInfo),
        };
        cmd.setData(pty);
        cmd.start(alloc) catch |err| switch (err) {
            error.ExecFailedInChild => return error.ExecFailedInChild,
            else => return error.SpawnFailed,
        };
        const pid: posix.pid_t = cmd.pid.?;
        errdefer posix.kill(pid, .TERM) catch {};

        // The parent never needs the slave side; closing it prevents
        // fd leaks into future children and lets the master see EOF
        // when the child (and its descendants) exit.
        _ = posix.system.close(pty.slave);

        var headless = Headless.init(alloc, cols, rows) catch
            return error.SpawnFailed;
        errdefer headless.deinit();

        self.* = .{
            .alloc = alloc,
            .pty = pty,
            .pid = pid,
            .master = pty.master,
            .headless = headless,
        };
        return self;
    }

    /// Free everything. Does NOT signal the child: only call this after
    /// `kill()` + reap, or when the child is known gone. (Detach never
    /// calls this — the whole point of AC1.1.)
    pub fn deinit(self: *DaemonPty) void {
        const alloc = self.alloc;
        self.headless.deinit();
        self.pty.deinit();
        alloc.destroy(self.pty);
        alloc.destroy(self);
    }

    /// Send SIGHUP to the child's process group. The child called
    /// setsid in pre-exec so it leads its own group (`-pid` addresses
    /// it). Call only on explicit session kill — never on detach.
    pub fn kill(self: *DaemonPty) void {
        posix.kill(-self.pid, .HUP) catch {};
    }

    /// Non-blocking reap check. Returns true once the child has exited
    /// (and reaps the zombie). Never blocks.
    pub fn pollExit(self: *DaemonPty) bool {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        const rc = posix.system.waitpid(self.pid, &status, std.c.W.NOHANG);
        return switch (posix.errno(rc)) {
            .SUCCESS => rc != 0,
            .CHILD => true, // already reaped / not ours: gone either way
            else => false,
        };
    }

    /// True while the child has not exited. (A zombie that we have not
    /// reaped yet still counts as exited: `pollExit` reaps it.)
    pub fn isAlive(self: *DaemonPty) bool {
        return !self.pollExit();
    }

    /// Write client bytes to the PTY master (terminal input).
    pub fn writeInput(self: *DaemonPty, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = posix.system.write(self.master, bytes[off..].ptr, bytes.len - off);
            const n: usize = switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            };
            if (n == 0) return error.WriteFailed;
            off += n;
        }
    }

    /// Read whatever output is available (up to `timeout_ns`) and feed
    /// it to the headless terminal. Returns true if any bytes flowed.
    /// A clean EOF (child exited, slave closed) marks `exited`.
    pub fn pump(self: *DaemonPty, timeout_ns: u64) !bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.master,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const timeout_ms: i32 = @intCast(@min(
            timeout_ns / std.time.ns_per_ms,
            std.math.maxInt(i32),
        ));
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return false;
        if (fds[0].revents & posix.POLL.HUP != 0) self.exited = true;
        return self.drain();
    }

    fn drain(self: *DaemonPty) !bool {
        var buf: [4096]u8 = undefined;
        var flowed = false;
        while (true) {
            const rc = posix.system.read(self.master, &buf, buf.len);
            const n: usize = switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                .AGAIN => break,
                // Linux PTYs report EIO instead of EOF once the slave
                // side is closed (all children gone). Treat like EOF.
                .IO => {
                    self.exited = true;
                    break;
                },
                else => |err| return posix.unexpectedErrno(err),
            };
            if (n == 0) {
                self.exited = true;
                break;
            }
            self.headless.feed(buf[0..n]);
            flowed = true;
            if (n < buf.len) break;
        }
        return flowed;
    }

    /// Resize the PTY and the headless grid together.
    pub fn resize(self: *DaemonPty, cols: u16, rows: u16) !void {
        self.pty.setSize(.{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        }) catch return error.ResizeFailed;
        self.headless.term.resize(self.alloc, .{
            .cols = cols,
            .rows = rows,
        }) catch return error.ResizeFailed;
    }
};

test "daemon pty: spawn echo, output lands on the grid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const argv = [_][:0]const u8{ "/bin/sh", "-c", "printf 'hi-wraith'" };
    var pty = try DaemonPty.spawn(alloc, &argv, null, 80, 24);
    defer {
        pty.kill();
        while (!pty.pollExit()) std.Io.sleep(
            testing.io,
            .fromMilliseconds(10),
            .awake,
        ) catch {};
        pty.deinit();
    }

    // Pump until the first row shows output (child may need a moment).
    const start = std.Io.Timestamp.now(testing.io, .awake);
    var seen = false;
    while (start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds() < 5 * std.time.ns_per_s) {
        _ = try pty.pump(100 * std.time.ns_per_ms);
        if (pty.headless.cellCodepoint(0, 0) == 'h') {
            seen = true;
            break;
        }
        if (pty.exited) break;
    }
    try testing.expect(seen);
    try testing.expectEqual(@as(u21, 'i'), pty.headless.cellCodepoint(1, 0));
}

test "daemon pty: child survives detach (no SIGHUP without kill)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const argv = [_][:0]const u8{ "/bin/sh", "-c", "sleep 30" };
    var pty = try DaemonPty.spawn(alloc, &argv, null, 80, 24);
    defer {
        pty.kill();
        while (!pty.pollExit()) std.Io.sleep(
            testing.io,
            .fromMilliseconds(10),
            .awake,
        ) catch {};
        pty.deinit();
    }

    // "Detach": do nothing to the pty at all — the way the session
    // manager detaches (state flip only). The child must still live.
    try testing.expect(pty.isAlive());
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    try testing.expect(pty.isAlive());

    // ...while an explicit kill actually ends it.
    pty.kill();
    const start = std.Io.Timestamp.now(testing.io, .awake);
    while (!pty.pollExit()) {
        if (start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds() > 5 * std.time.ns_per_s)
            return error.KillTimeout;
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
}

test "daemon pty: input reaches the child, resize works" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const argv = [_][:0]const u8{ "/bin/sh", "-c", "read line; printf \"got:$line\"; sleep 5" };
    var pty = try DaemonPty.spawn(alloc, &argv, null, 80, 24);
    defer {
        pty.kill();
        while (!pty.pollExit()) std.Io.sleep(
            testing.io,
            .fromMilliseconds(10),
            .awake,
        ) catch {};
        pty.deinit();
    }

    try pty.resize(100, 30);
    try testing.expectEqual(@as(u16, 100), pty.headless.term.cols);
    try pty.writeInput("abc\n");

    const start = std.Io.Timestamp.now(testing.io, .awake);
    var seen = false;
    while (start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds() < 5 * std.time.ns_per_s) {
        _ = try pty.pump(100 * std.time.ns_per_ms);
        // PTY echo puts our typed "abc" on row 0, so the child's reply
        // lands on a later row: scan the whole grid for "got:abc".
        var y: u16 = 0;
        while (y < 30) : (y += 1) {
            var x: u16 = 0;
            while (x < 93) : (x += 1) {
                if (pty.headless.cellCodepoint(x, y) == 'g' and
                    pty.headless.cellCodepoint(x + 1, y) == 'o' and
                    pty.headless.cellCodepoint(x + 4, y) == 'a')
                {
                    seen = true;
                    break;
                }
            }
            if (seen) break;
        }
        if (seen) break;
    }
    try testing.expect(seen);
}
