const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const Client = @import("../daemon/client.zig").Client;
const SessionId = @import("../daemon/id.zig").SessionId;
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

/// Kill a WraithTerm daemon session by id: `ghostty +kill <id>`.
///
/// The id is positional. Like `ssh-cache` (the repo's positional-args
/// precedent): the positional is lifted out first and only the
/// remaining flags go through `args.parse`, which rejects bare
/// positionals.
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag != .linux) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("kill: only supported on Linux\n") catch {};
        stderr_writer.end() catch {};
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tmp = arena.allocator();

    var target: ?[]const u8 = null;
    var flags: std.ArrayList([]const u8) = .empty;
    {
        var iter = try args.argsIterator(gpa, global.args());
        defer iter.deinit();
        while (iter.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                if (target == null) target = try tmp.dupe(u8, arg);
            } else {
                try flags.append(tmp, try tmp.dupe(u8, arg));
            }
        }
    }
    {
        var iter = args.sliceIterator(flags.items);
        try args.parse(Options, gpa, &opts, &iter);
    }

    const id_str = target orelse {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("Usage: ghostty +kill <session-id>\n") catch {};
        stderr_writer.end() catch {};
        return 1;
    };
    // Validate the id before touching the daemon.
    _ = SessionId.parse(id_str) catch {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.print("kill: invalid session id '{s}'\n", .{id_str}) catch {};
        stderr_writer.end() catch {};
        return 1;
    };

    const path = try wraith_control.controlSocketPath(gpa);
    defer gpa.free(path);

    var cli = wraith_control.connectOrSpawn(gpa, path) catch {
        return daemonUnreachable();
    };
    defer cli.deinit();
    cli.helloCli(id_str) catch {
        return daemonUnreachable();
    };
    cli.killSession() catch {
        return daemonUnreachable();
    };
    return 0;
}

fn daemonUnreachable() u8 {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    stderr_writer.interface.writeAll("kill: daemon unreachable\n") catch {};
    stderr_writer.end() catch {};
    return 1;
}
