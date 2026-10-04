const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const bootstrap = @import("../daemon/ssp_bootstrap.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Connect to a remote WraithTerm session (P4.3: SSH bootstrap).
/// Usage: `ghostty +remote user@host[:port] [-- <remote args>]`.
///
/// Runs `ssh` to start `wraith --remote-server` remotely, reads the
/// `WRAITH CONNECT` line (60 s deadline, D2), and reports the UDP
/// endpoint. The UDP session itself lands in P4.4.
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag != .linux) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("remote: only supported on Linux\n") catch {};
        stderr_writer.end() catch {};
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    var target: ?[]const u8 = null;
    defer if (target) |t| gpa.free(t);
    {
        var iter = try args.argsIterator(gpa, global.args());
        defer iter.deinit();
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return Action.help_error;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (target == null) target = try gpa.dupe(u8, arg);
            }
        }
    }

    const dst = target orelse {
        fail("Usage: ghostty +remote user@host[:port]");
        return 1;
    };
    // Split optional :port (ssh default 22 when absent).
    var host = dst;
    var ssh_port: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, dst, ':')) |ci| {
        // Bare IPv6 (`::`) without brackets is ambiguous: pass through.
        if (std.mem.indexOfScalar(u8, dst, ':') != ci) {
            host = dst;
        } else {
            host = dst[0..ci];
            ssh_port = dst[ci + 1 ..];
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "ssh", "-o", "BatchMode=yes", "-T" });
    if (ssh_port) |p| try argv.appendSlice(gpa, &.{ "-p", p });
    try argv.appendSlice(gpa, &.{ host, "wraith", "--remote-server" });

    var child = std.process.spawn(global.io(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        fail("remote: cannot spawn ssh");
        return 1;
    };
    defer {
        child.kill(global.io());
    }
    const out = child.stdout orelse {
        fail("remote: no ssh stdout");
        return 1;
    };
    const info = bootstrap.readConnectLine(
        gpa,
        global.io(),
        out,
        bootstrap.connect_timeout_ns,
    ) catch {
        fail("remote: no WRAITH CONNECT line (timeout or refused)");
        return 1;
    };

    var out_buf: [256]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(global.io(), &out_buf);
    out_writer.interface.print(
        "remote: endpoint {s} UDP/{d} (session key accepted, P4.4 attaches the session)\n",
        .{ host, info.udp_port },
    ) catch {};
    out_writer.end() catch {};
    return 0;
}

fn fail(msg: []const u8) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    stderr_writer.interface.writeAll(msg) catch {};
    stderr_writer.interface.writeAll("\n") catch {};
    stderr_writer.end() catch {};
}
