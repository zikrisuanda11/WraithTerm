const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");

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

/// Uninstall the omp bridge extension (P1.1 stub: not yet implemented).
pub fn run(gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa, global.args());
        defer iter.deinit();
        try args.parse(Options, gpa, &opts, &iter);
    }

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll("uninstall-omp-bridge: not implemented\n") catch {};
    stderr.flush() catch {};
    return 1;
}
