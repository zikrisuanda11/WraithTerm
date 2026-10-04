const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const bootstrap = @import("../daemon/ssp_bootstrap.zig");

pub const Options = struct {
    /// UDP port to bind (0 = ephemeral). Rarely set manually; the
    /// client learns the port from the CONNECT line.
    port: u16 = 0,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Serve a remote WraithTerm session over SSP (server side, D2).
/// Binds UDP, prints `WRAITH CONNECT <port> <key>` to stdout, and
/// waits for the first client packet (60 s). The session loop itself
/// lands in P4.4; this proves bootstrap end-to-end over real UDP.
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag != .linux) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("remote-server: only supported on Linux\n") catch {};
        stderr_writer.end() catch {};
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa, global.args());
        defer iter.deinit();
        try args.parse(Options, gpa, &opts, &iter);
    }

    const linux = std.os.linux;
    const fd: linux.socket_t = blk: {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        const signed: isize = @bitCast(rc);
        if (signed < 0 and signed >= -4095) {
            fail("remote-server: cannot create UDP socket");
            return 1;
        }
        break :blk @intCast(rc);
    };
    defer _ = linux.close(fd);

    var addr = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, opts.port);
    addr.addr = 0;
    {
        const rc = linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        const signed: isize = @bitCast(rc);
        if (signed < 0 and signed >= -4095) {
            fail("remote-server: cannot bind UDP socket");
            return 1;
        }
    }
    var bound = std.mem.zeroes(linux.sockaddr.in);
    var bound_len: linux.socklen_t = @sizeOf(@TypeOf(bound));
    {
        const rc = linux.getsockname(fd, @ptrCast(&bound), &bound_len);
        const signed: isize = @bitCast(rc);
        if (signed < 0 and signed >= -4095) {
            fail("remote-server: cannot read bound port");
            return 1;
        }
    }
    const port = std.mem.bigToNative(u16, bound.port);

    var key: [32]u8 = undefined;
    global.io().randomSecure(&key) catch {
        fail("remote-server: no entropy for session key");
        return 1;
    };

    const line = bootstrap.formatConnectLine(gpa, port, key) catch {
        fail("remote-server: cannot format CONNECT line");
        return 1;
    };
    defer gpa.free(line);
    {
        var out_buf: [128]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(global.io(), &out_buf);
        out_writer.interface.writeAll(line) catch {};
        out_writer.interface.writeAll("\n") catch {};
        out_writer.end() catch {};
    }

    // Wait for the first client packet (D2: 60 s, then self-close).
    const start = std.Io.Timestamp.now(global.io(), .awake);
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const now = std.Io.Timestamp.now(global.io(), .awake);
        const elapsed: u64 = @intCast(@max(start.durationTo(now).toNanoseconds(), 0));
        if (elapsed > bootstrap.connect_timeout_ns) {
            fail("remote-server: no client packet within 60s");
            return 1;
        }
        const n = std.posix.poll(&fds, 200) catch {
            fail("remote-server: poll failed");
            return 1;
        };
        if (n == 0) continue;
        var pkt: [1500]u8 = undefined;
        var src: linux.sockaddr.in = undefined;
        var src_len: linux.socklen_t = @sizeOf(@TypeOf(src));
        const rc = linux.recvfrom(fd, &pkt, pkt.len, 0, @ptrCast(&src), &src_len);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) continue;
        const got: usize = @intCast(signed);
        var err_buf: [256]u8 = undefined;
        var err_writer = std.Io.File.stderr().writer(global.io(), &err_buf);
        err_writer.interface.print(
            "remote-server: first packet ({d} B), session key active\n",
            .{got},
        ) catch {};
        err_writer.end() catch {};
        return 0;
    }
}

fn fail(msg: []const u8) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    stderr_writer.interface.writeAll(msg) catch {};
    stderr_writer.interface.writeAll("\n") catch {};
    stderr_writer.end() catch {};
}
