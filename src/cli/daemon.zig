const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const Server = @import("../daemon/server.zig").Server;
const controlSocketPath = @import("wraith_control.zig").controlSocketPath;

pub const Options = struct {
    /// Exit once no sessions remain (D8). Without it the daemon
    /// serves until killed.
    @"exit-when-empty": bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Start the WraithTerm daemon in the foreground: bind the control
/// socket and serve connections until killed (or, with
/// `--exit-when-empty`, until no sessions remain).
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag != .linux) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("daemon: only supported on Linux\n") catch {};
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

    const path = try controlSocketPath(gpa);
    defer gpa.free(path);

    var srv = Server.init(gpa, global.io(), global.environ(), path) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.print("daemon: cannot listen: {t}\n", .{err}) catch {};
        stderr_writer.end() catch {};
        return 1;
    };
    defer srv.deinit();
    if (opts.@"exit-when-empty") srv.exit_when_empty = true;
    srv.run();
    return 0;
}
