//! Shared control-plane helpers for the WraithTerm CLI actions
//! (`+list-sessions`, `+kill`, `+daemon`). Linux-only in v1, like the
//! rest of `src/daemon`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const Config = @import("../config.zig").Config;
const Client = @import("../daemon/client.zig").Client;
const sock = @import("../daemon/socket.zig");

/// Resolve the daemon control socket path from the process
/// environment (repo pattern: libs never read globals, so the
/// environ is fetched here at the CLI edge).
pub fn controlSocketPath(alloc: Allocator) ![]u8 {
    return sock.socketPath(alloc, global.environ());
}

/// How long `ensureDaemon` waits for an on-demand daemon to bind
/// its socket before giving up.
pub const spawn_wait_ms = 5000;

/// Connect to the daemon at `path`, starting it on demand when
/// `wraith-daemon = auto` (D8) and the socket is missing. Returns a
/// connected client; the caller owns it.
pub fn connectOrSpawn(alloc: Allocator, path: []const u8) !Client {
    if (Client.connect(alloc, path)) |cli| return cli else |_| {}
    if (!daemonAuto(alloc)) return error.DaemonUnreachable;
    try spawnDaemon(alloc);
    const start = std.Io.Timestamp.now(global.io(), .awake);
    while (true) {
        if (Client.connect(alloc, path)) |cli| return cli else |_| {}
        const now = std.Io.Timestamp.now(global.io(), .awake);
        if (start.durationTo(now).toMilliseconds() > spawn_wait_ms) {
            return error.DaemonUnreachable;
        }
        std.Io.sleep(global.io(), .fromMilliseconds(50), .awake) catch {};
    }
}

/// Read `wraith-daemon` from the user config. Any load failure
/// means stock behavior (`off`): never break the CLI because a
/// config file is unreadable.
fn daemonAuto(alloc: Allocator) bool {
    var cfg = Config.load(alloc) catch return false;
    defer cfg.deinit();
    cfg.finalize() catch return false;
    return cfg.@"wraith-daemon" == .auto;
}

/// Spawn `ghostty +daemon` detached: the child outlives this
/// process (reparented on our exit, so no zombie) and serves the
/// control socket.
fn spawnDaemon(alloc: Allocator) !void {
    _ = alloc;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(global.io(), &exe_buf)];
    // Detached by design: we never wait on the child, so it is
    // reparented on our exit (no zombie) and keeps serving.
    _ = try std.process.spawn(global.io(), .{
        .argv = &.{ exe, "+daemon" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}
