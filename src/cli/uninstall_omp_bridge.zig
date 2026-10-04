const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const homedir = @import("../os/homedir.zig");
const installer = @import("../daemon/harness_install.zig");

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

/// Remove the WraithTerm omp bridge extension, but only when the
/// file at our path carries our marker. Never deletes foreign
/// files; succeeds silently when nothing is installed.
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag == .windows) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("uninstall-omp-bridge: unsupported on Windows\n") catch {};
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

    var env_map = try global.environMap();
    defer env_map.deinit();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try homedir.home(global.io(), &env_map, &home_buf) orelse {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("uninstall-omp-bridge: cannot resolve home directory\n") catch {};
        stderr_writer.end() catch {};
        return 1;
    };

    const removed = installer.uninstall(gpa, global.io(), home) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.print("uninstall-omp-bridge: {t}\n", .{err}) catch {};
        stderr_writer.end() catch {};
        return 1;
    };

    var out_buf: [256]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(global.io(), &out_buf);
    const out = &out_writer.interface;
    if (removed) {
        out.writeAll("removed wraith-omp-bridge.ts\n") catch {};
    } else {
        out.writeAll("wraith-omp-bridge.ts not installed\n") catch {};
    }
    out_writer.end() catch {};
    return 0;
}
