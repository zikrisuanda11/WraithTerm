const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const Client = @import("../daemon/client.zig").Client;
const wraith_control = @import("wraith_control.zig");
const hlist = @import("../daemon/harness_list.zig");
const hevent = @import("../daemon/harness_event.zig");
const SessionId = @import("../daemon/id.zig").SessionId;

pub const Options = struct {
    /// Emit JSON instead of human-readable text (D5: feeds tooling).
    json: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// List harness (agent) activity per session, merging Tier 1 bridge
/// state with Tier 2 process detection (P2.7).
pub fn run(gpa: Allocator) !u8 {
    if (comptime @import("builtin").os.tag != .linux) {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        stderr_writer.interface.writeAll("list-harnesses: only supported on Linux\n") catch {};
        stderr_writer.end() catch {};
        return 1;
    }

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa, global.args());
        defer iter.deinit();
        // `--json` is a plain bool flag, parsed the usual way. The
        // action takes no positionals.
        try args.parse(Options, gpa, &opts, &iter);
    }

    const path = try wraith_control.controlSocketPath(gpa);
    defer gpa.free(path);

    var cli = wraith_control.connectOrSpawn(gpa, path) catch {
        return daemonUnreachable();
    };
    defer cli.deinit();
    cli.helloCli("") catch {
        return daemonUnreachable();
    };
    const entries = cli.queryHarnesses() catch {
        return daemonUnreachable();
    };
    defer gpa.free(entries);

    const rows = try gpa.alloc(hlist.HarnessRow, entries.len);
    defer gpa.free(rows);
    for (entries, 0..) |*e, i| {
        var tmp: SessionId = undefined;
        @memcpy(&tmp.bytes, &e.id);
        var hex: [SessionId.len]u8 = undefined;
        const id_str = tmp.toString(&hex);
        var id: [8]u8 = undefined;
        @memcpy(&id, id_str);
        rows[i] = .{
            .id = id,
            .tier1 = hevent.State.fromOrdinal(e.tier1) orelse .unknown,
            .tier2 = e.tier2 != 0,
        };
        if (e.tool_len > 0) {
            rows[i].tool = e.tool[0..@min(e.tool_len, 32)];
        }
    }

    const rendered = if (opts.json)
        try hlist.formatJson(gpa, rows)
    else
        try hlist.formatText(gpa, rows);
    defer gpa.free(rendered);

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(global.io(), &out_buf);
    out_writer.interface.writeAll(rendered) catch {};
    out_writer.end() catch {};
    return 0;
}

fn daemonUnreachable() u8 {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    stderr_writer.interface.writeAll("list-harnesses: daemon unreachable\n") catch {};
    stderr_writer.end() catch {};
    return 1;
}
