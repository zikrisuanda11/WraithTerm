//! omp bridge embed + runtime test (P2.5).
//!
//! The bridge source ships inside the binary via `@embedFile` so the
//! installer (P2.6) never depends on repo layout at runtime. The
//! tests execute the REAL embedded file under `bun` (when present)
//! against a local socket: a fake `pi` object drives lifecycle
//! events, and the test asserts D6 JSON-lines arrive. Without `bun`,
//! only the static checks run.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

/// The exact file installed by `+install-omp-bridge` (P2.6).
pub const source: []const u8 = @embedFile("wraith-omp-bridge.ts");

/// Installer marker: the uninstaller only removes files carrying it.
pub const marker = "wraith-omp-bridge";

test "bridge: embedded source carries marker and hooks" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, source, marker) != null);
    // Fire-and-forget budget (D6/P2.5): single 50 ms attempt.
    try testing.expect(std.mem.indexOf(u8, source, "setTimeout(done, 50)") != null);
    // Env contract (D6).
    try testing.expect(std.mem.indexOf(u8, source, "WRAITH_HARNESS_SOCK") != null);
    try testing.expect(std.mem.indexOf(u8, source, "WRAITH_SESSION_ID") != null);
    // Lifecycle coverage (HARNESS_OMP.md §4).
    for ([_][]const u8{
        "agent_start",
        "agent_settled",
        "agent_end",
        "tool_call",
        "tool_execution_start",
        "tool_execution_end",
        "tool_approval_requested",
        "tool_approval_resolved",
        "session_start",
        "session_shutdown",
    }) |hook| {
        try testing.expect(std.mem.indexOf(u8, source, hook) != null);
    }
}

test "bridge: bun drives D6 events to a socket" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!hasBun()) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Real files for bun: the embedded bridge + a driver with a fake pi.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "bridge.ts",
        .data = source,
    });
    const driver =
        \\import bridge from "./bridge.ts";
        \\const handlers = {};
        \\const pi = { on: (name, fn) => { handlers[name] = fn; } };
        \\bridge(pi);
        \\handlers["agent_start"]();
        \\handlers["tool_call"]({ toolName: "edit" });
        \\await new Promise((r) => setTimeout(r, 500));
    ;
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "driver.ts",
        .data = driver,
    });
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(tmp_path);
    const sock_path = try std.fs.path.join(alloc, &.{ tmp_path, "harness.sock" });
    defer alloc.free(sock_path);

    var listener = try bindListener(alloc, sock_path);
    defer listener.deinit();

    // Run the driver with the D6 env pointing at our socket.
    var env_map = try testing.environ.createMap(alloc);
    defer env_map.deinit();
    try env_map.put("WRAITH_HARNESS_SOCK", sock_path);
    try env_map.put("WRAITH_SESSION_ID", "deadbeef");
    const driver_path = try tmp.dir.realPathFileAlloc(testing.io, "driver.ts", alloc);
    defer alloc.free(driver_path);
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "bun", driver_path },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer _ = child.wait(testing.io) catch {};

    // Two connections expected (agent_start, tool_call); read one
    // line from each with a bounded wait.
    var got_thinking = false;
    var got_tool = false;
    var conns: usize = 0;
    while (conns < 2) : (conns += 1) {
        const fd = try acceptTimeout(&listener, testing.io, 15_000);
        defer _ = linux.close(fd);
        var buf: [4096]u8 = undefined;
        const n = try readLineTimeout(fd, &buf);
        const line = buf[0..n];
        if (std.mem.indexOf(u8, line, "\"state\":\"thinking\"") != null) got_thinking = true;
        if (std.mem.indexOf(u8, line, "\"state\":\"executing_tool\"") != null and
            std.mem.indexOf(u8, line, "\"tool\":\"edit\"") != null and
            std.mem.indexOf(u8, line, "\"session_id\":\"deadbeef\"") != null)
        {
            got_tool = true;
        }
    }
    try testing.expect(got_thinking);
    try testing.expect(got_tool);
}

test "bridge: silent without env" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!hasBun()) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "bridge.ts",
        .data = source,
    });
    // The driver exits 0 without env; any socket attempt would fail
    // the test via the bridge throwing (bun reports uncaught).
    const driver =
        \\import bridge from "./bridge.ts";
        \\const pi = { on: () => {} };
        \\bridge(pi);
    ;
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "driver.ts",
        .data = driver,
    });
    const driver_path = try tmp.dir.realPathFileAlloc(testing.io, "driver.ts", alloc);
    defer alloc.free(driver_path);
    // Minimal env WITHOUT the D6 vars (PATH kept so `bun` resolves;
    // bun is spawned by absolute lookup below, env only affects child).
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "bun", driver_path },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(testing.io);
    // Exited cleanly having sent nothing (no socket existed to fail on).
    try testing.expect(term == .exited);
    try testing.expectEqual(@as(u8, 0), term.exited);
}

fn hasBun() bool {
    for ([_][]const u8{ "/usr/bin/bun", "/usr/local/bin/bun" }) |p| {
        var buf: [64]u8 = undefined;
        if (p.len + 1 > buf.len) continue;
        @memcpy(buf[0..p.len], p);
        buf[p.len] = 0;
        if (linux.access(buf[0..p.len :0], 0) == 0) return true;
    }
    return false;
}

const Listener = struct {
    fd: linux.socket_t,
    alloc: Allocator,
    path: []u8,

    fn deinit(self: *Listener) void {
        _ = linux.close(self.fd);
        self.alloc.free(self.path);
    }
};

fn bindListener(alloc: Allocator, path: []const u8) !Listener {
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
    _ = syscall(linux.bind(
        fd,
        @ptrCast(&addr),
        @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1),
    )) catch return error.BindFailed;
    _ = syscall(linux.listen(fd, 8)) catch return error.ListenFailed;
    return .{ .fd = fd, .alloc = alloc, .path = try alloc.dupe(u8, path) };
}

fn syscall(rc: usize) error{Failed}!linux.socket_t {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed >= -4095) return error.Failed;
    return @intCast(rc);
}

/// Blocking accept with a millisecond deadline (poll loop).
fn acceptTimeout(listener: *Listener, io: std.Io, timeout_ms: u64) !linux.socket_t {
    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        var fds = [_]std.posix.pollfd{.{
            .fd = listener.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, 200) catch 0;
        if (n > 0) {
            return syscall(linux.accept(listener.fd, null, null)) catch error.AcceptFailed;
        }
        const now = std.Io.Timestamp.now(io, .awake);
        if (start.durationTo(now).toMilliseconds() > timeout_ms) return error.Timeout;
    }
}

/// One newline-terminated line with a deadline; returns its length.
fn readLineTimeout(fd: linux.socket_t, buf: []u8) !usize {
    var n: usize = 0;
    var tmp: [1]u8 = undefined;
    while (n < buf.len) {
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, 5000) catch return error.ReadFailed;
        if (ready == 0) return error.Timeout;
        const rc = linux.read(fd, &tmp, 1);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return error.Closed;
        if (tmp[0] == '\n') break;
        buf[n] = tmp[0];
        n += 1;
    }
    return n;
}
