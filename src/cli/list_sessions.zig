const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const Client = @import("../daemon/client.zig").Client;
const wraith_control = @import("wraith_control.zig");

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

/// List WraithTerm daemon sessions, one `id state` row per line.
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag != .linux) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("list-sessions: only supported on Linux\n") catch {};
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

    const path = try wraith_control.controlSocketPath(gpa);
    defer gpa.free(path);

    var cli = wraith_control.connectOrSpawn(gpa, path) catch {
        return daemonUnreachable(gpa);
    };
    defer cli.deinit();
    cli.helloCli("") catch {
        return daemonUnreachable(gpa);
    };
    const rows = cli.listSessions() catch {
        return daemonUnreachable(gpa);
    };
    defer gpa.free(rows);

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(global.io(), &out_buf);
    const out = &out_writer.interface;
    for (rows) |row| {
        const state: []const u8 = switch (row.state) {
            0 => "detached",
            1 => "attached",
            2 => "closing",
            else => "unknown",
        };
        out.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2} {s}\n", .{
            row.id[0],
            row.id[1],
            row.id[2],
            row.id[3],
            state,
        }) catch {};
    }
    out_writer.end() catch {};
    return 0;
}

fn daemonUnreachable(gpa: Allocator) u8 {
    _ = gpa;
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    stderr_writer.interface.writeAll("list-sessions: daemon unreachable\n") catch {};
    stderr_writer.end() catch {};
    return 1;
}
