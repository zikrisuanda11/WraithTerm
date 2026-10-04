//! Headless test client for the daemon control socket (P1.7).
//!
//! Connects, sends `codec` messages, and reads replies. Used by the
//! attach/detach integration tests; later the GUI attach path can
//! reuse the same framing helpers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const codec = @import("codec.zig");
const server = @import("server.zig");
const daemon_snapshot = @import("snapshot.zig");
const Terminal = @import("../terminal/Terminal.zig");
const SessionId = @import("id.zig").SessionId;
const session = @import("session.zig");

pub const Client = struct {
    alloc: Allocator,
    fd: linux.socket_t,

    pub fn connect(alloc: Allocator, path: []const u8) !Client {
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
        _ = syscall(linux.connect(
            fd,
            @ptrCast(&addr),
            @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1),
        )) catch return error.ConnectFailed;
        return .{ .alloc = alloc, .fd = fd };
    }

    pub fn deinit(self: *Client) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    pub fn send(self: *Client, msg: codec.Message) !void {
        try server.writeMessage(self.fd, self.alloc, msg);
    }

    pub fn recv(self: *Client) !server.InMessage {
        return server.readMessage(self.alloc, self.fd) catch error.RecvFailed;
    }

    /// Attach (empty id = create). Reads snapshot chunks until the
    /// full set arrives and returns the joined payloads.
    pub fn hello(self: *Client, id: []const u8) !struct {
        state_id: u32,
        cols: u16,
        rows: u16,
        payloads: [][]u8,
    } {
        try self.send(.{ .hello = .{
            .version_min = 1,
            .version_max = codec.protocol_version,
            .capabilities = 0,
            .role = .client,
            .id = id,
        } });
        var first = try self.recv();
        defer first.deinit();
        const s0 = first.owned.msg.snapshot;
        const payloads = try self.alloc.alloc([]u8, s0.chunk_count);
        for (payloads) |*slot| slot.* = &.{};
        errdefer {
            for (payloads) |p| if (p.len > 0) self.alloc.free(p);
            self.alloc.free(payloads);
        }
        payloads[s0.chunk_index] = try self.alloc.dupe(u8, s0.payload);
        var got: usize = 1;
        while (got < s0.chunk_count) {
            var m = try self.recv();
            defer m.deinit();
            const s = m.owned.msg.snapshot;
            payloads[s.chunk_index] = try self.alloc.dupe(u8, s.payload);
            got += 1;
        }
        return .{
            .state_id = s0.state_id,
            .cols = s0.cols,
            .rows = s0.rows,
            .payloads = payloads,
        };
    }

    pub fn freePayloads(self: *Client, payloads: [][]u8) void {
        for (payloads) |p| self.alloc.free(p);
        self.alloc.free(payloads);
    }

    /// Control-plane hello (`role=cli`): no session is created;
    /// the server replies `ack`. `id` selects a kill target or is
    /// empty for `list_sessions` / `exit_when_empty`.
    pub fn helloCli(self: *Client, id: []const u8) !void {
        try self.send(.{ .hello = .{
            .version_min = 1,
            .version_max = codec.protocol_version,
            .capabilities = 0,
            .role = .cli,
            .id = id,
        } });
        var ack = try self.recv();
        defer ack.deinit();
        if (ack.owned.msg != .ack) return error.ExpectedAck;
    }

    /// Request the session list. Caller owns the returned entries.
    pub fn listSessions(self: *Client) ![]codec.SessionListEntry {
        try self.send(.{ .control = .{ .command = .list_sessions } });
        var reply = try self.recv();
        defer reply.deinit();
        if (reply.owned.msg != .session_list) return error.ExpectedList;
        return self.alloc.dupe(
            codec.SessionListEntry,
            reply.owned.msg.session_list.entries,
        ) catch return error.OutOfMemory;
    }

    /// Request the merged Tier 1 + Tier 2 harness view. Caller owns
    /// the returned entries.
    pub fn queryHarnesses(self: *Client) ![]codec.HarnessListEntry {
        try self.send(.{ .control = .{ .command = .query_harnesses } });
        var reply = try self.recv();
        defer reply.deinit();
        if (reply.owned.msg != .harness_list) return error.ExpectedList;
        return self.alloc.dupe(
            codec.HarnessListEntry,
            reply.owned.msg.harness_list.entries,
        ) catch return error.OutOfMemory;
    }

    /// Kill the session selected by `helloCli`. The server replies
    /// `ack`, then closes the connection.
    pub fn killSession(self: *Client) !void {
        try self.send(.{ .control = .{ .command = .kill_session } });
        var ack = try self.recv();
        defer ack.deinit();
        if (ack.owned.msg != .ack) return error.ExpectedAck;
    }

    /// Set the daemon's `--exit-when-empty` latch (D8).
    pub fn setExitWhenEmpty(self: *Client, on: bool) !void {
        try self.send(.{ .control = .{
            .command = .exit_when_empty,
            .on = if (on) 1 else 0,
            .has_on = true,
        } });
        var ack = try self.recv();
        defer ack.deinit();
        if (ack.owned.msg != .ack) return error.ExpectedAck;
    }
    /// Restore a terminal from joined snapshot payloads.
    pub fn restore(
        self: *Client,
        io: std.Io,
        payloads: [][]u8,
    ) !Terminal {
        const const_payloads = try self.alloc.alloc([]const u8, payloads.len);
        defer self.alloc.free(const_payloads);
        for (payloads, 0..) |p, i| const_payloads[i] = p;
        var decoded = try daemon_snapshot.restore(
            self.alloc,
            io,
            const_payloads,
            1024,
        );
        defer decoded.deinit(self.alloc);
        return decoded.toOwned();
    }
};

fn syscall(rc: usize) error{Failed}!linux.socket_t {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed >= -4095) return error.Failed;
    return @intCast(rc);
}

test "daemon attach: spawn, detach, reattach keeps child and screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const tmp = testing.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(alloc, "{s}/wraith-p17-{d}/ctl.sock", .{ tmp, linux.getpid() });
    defer alloc.free(path);

    var srv = try @import("server.zig").Server.init(alloc, testing.io, testing.environ, path);
    defer srv.deinit();

    // Server thread serves two connections: create + reattach.
    // Each connection gets its own serving thread: conn #1 stays
    // open across the whole marker loop, so sequential acceptOnce
    // would deadlock.
    const ServeTwo = struct {
        fn run(s: *@import("server.zig").Server) void {
            const fd1 = s.acceptFd() catch return;
            const t1 = std.Thread.spawn(.{}, @import("server.zig").Server.serveFd, .{ s, fd1 }) catch {
                _ = linux.close(fd1);
                return;
            };
            const fd2 = s.acceptFd() catch {
                t1.join();
                return;
            };
            s.serveFd(fd2);
            t1.join();
        }
    };
    const thread = try std.Thread.spawn(.{}, ServeTwo.run, .{&srv});

    var c1 = try Client.connect(alloc, path);
    const snap1 = try c1.hello("");
    // `hello` returns only after the server sent the full snapshot,
    // which happens after it stored `last_id`: safe to read here.
    const sid = srv.last_id.?;
    var id_buf: [SessionId.len]u8 = undefined;
    const id_str = sid.toString(&id_buf);

    // The fresh shell shows an empty grid; write a marker via input.
    try c1.send(.{ .input = .{ .kind = .text, .data = "printf MARKER123\n" } });
    // Ask for a fresh snapshot and wait for the marker to appear.
    var marker_seen = false;
    var payloads: [][]u8 = snap1.payloads;
    var attempt: usize = 0;
    while (attempt < 30 and !marker_seen) : (attempt += 1) {
        c1.freePayloads(payloads);
        try c1.send(.{ .control = .{ .command = .request_snapshot } });
        var first = try c1.recv();
        defer first.deinit();
        const s0 = first.owned.msg.snapshot;
        payloads = try alloc.alloc([]u8, s0.chunk_count);
        for (payloads) |*slot| slot.* = &.{};
        payloads[s0.chunk_index] = try alloc.dupe(u8, s0.payload);
        var got: usize = 1;
        while (got < s0.chunk_count) {
            var m = try c1.recv();
            defer m.deinit();
            payloads[m.owned.msg.snapshot.chunk_index] = try alloc.dupe(u8, m.owned.msg.snapshot.payload);
            got += 1;
        }
        {
            var term = try c1.restore(testing.io, payloads);
            defer term.deinit(alloc);
            marker_seen = gridContains(&term, "MARKER123");
        }
    }
    try testing.expect(marker_seen);
    c1.freePayloads(payloads);

    // Detach: the child must stay alive without any client.
    try c1.send(.{ .control = .{ .command = .detach } });
    {
        var ack = try c1.recv();
        defer ack.deinit();
        try testing.expect(ack.owned.msg == .ack);
    }
    c1.deinit();
    // Session metadata flips back to detached, child alive.
    try testing.expectEqual(session.State.detached, srv.manager.get(sid).?.state);
    try testing.expect(srv.live.getPtr(sid.bytes).?.pty.isAlive());

    // Reattach with the same id: same screen content.
    var c2 = try Client.connect(alloc, path);
    const snap2 = try c2.hello(id_str);
    var term2 = try c2.restore(testing.io, snap2.payloads);
    defer term2.deinit(alloc);
    c2.freePayloads(snap2.payloads);
    const found2 = gridContains(&term2, "MARKER123");
    try testing.expect(found2);
    c2.deinit();

    thread.join();
}

test "daemon attach: second attach takes over, old client detached" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const tmp = testing.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(alloc, "{s}/wraith-p17take-{d}/ctl.sock", .{ tmp, linux.getpid() });
    defer alloc.free(path);

    var srv = try @import("server.zig").Server.init(alloc, testing.io, testing.environ, path);
    defer srv.deinit();

    const Server = @import("server.zig").Server;
    const ServeTwo = struct {
        fn run(s: *Server) void {
            const fd1 = s.acceptFd() catch return;
            const t1 = std.Thread.spawn(.{}, Server.serveFd, .{ s, fd1 }) catch {
                _ = linux.close(fd1);
                return;
            };
            const fd2 = s.acceptFd() catch {
                t1.join();
                return;
            };
            s.serveFd(fd2);
            t1.join();
        }
    };
    const thread = try std.Thread.spawn(.{}, ServeTwo.run, .{&srv});

    // First client creates and stays connected.
    var c1 = try Client.connect(alloc, path);
    const snap1 = try c1.hello("");
    c1.freePayloads(snap1.payloads);
    const sid = srv.last_id.?;
    var id_buf: [SessionId.len]u8 = undefined;
    const id_str = sid.toString(&id_buf);

    // Second client attaches to the same id while the first is live.
    var c2 = try Client.connect(alloc, path);
    const snap2 = try c2.hello(id_str);
    c2.freePayloads(snap2.payloads);

    // The first client must observe Detached{taken_over}.
    var note = try c1.recv();
    defer note.deinit();
    try testing.expectEqual(codec.DetachReason.taken_over, note.owned.msg.detached.reason);

    c1.deinit();
    c2.deinit();
    thread.join();
}

test "daemon control: list, kill, exit-when-empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const tmp = testing.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(alloc, "{s}/wraith-p18ctl-{d}/ctl.sock", .{ tmp, linux.getpid() });
    defer alloc.free(path);

    var srv = try @import("server.zig").Server.init(alloc, testing.io, testing.environ, path);
    defer srv.deinit();

    // c1 stays connected while the CLI-style conns come and go, so
    // each accepted fd gets its own serving thread (P1.7 lesson:
    // sequential acceptOnce deadlocks here).
    const Server = @import("server.zig").Server;
    const ServeN = struct {
        fn run(s: *Server) void {
            var threads: [5]std.Thread = undefined;
            var n: usize = 0;
            while (n < 5) : (n += 1) {
                const fd = s.acceptFd() catch break;
                threads[n] = std.Thread.spawn(.{}, Server.serveFd, .{ s, fd }) catch {
                    _ = linux.close(fd);
                    break;
                };
            }
            for (threads[0..n]) |t| t.join();
        }
    };
    const thread = try std.Thread.spawn(.{}, ServeN.run, .{&srv});

    // Empty daemon lists zero sessions.
    {
        var cli = try Client.connect(alloc, path);
        defer cli.deinit();
        try cli.helloCli("");
        const rows = try cli.listSessions();
        defer alloc.free(rows);
        try testing.expectEqual(@as(usize, 0), rows.len);
    }

    // Create one session via the attach path, keep it connected.
    var c1 = try Client.connect(alloc, path);
    const snap1 = try c1.hello("");
    c1.freePayloads(snap1.payloads);
    const sid = srv.last_id.?;
    var id_buf: [SessionId.len]u8 = undefined;
    const id_str = sid.toString(&id_buf);

    // List now shows one attached session with the right id.
    {
        var cli = try Client.connect(alloc, path);
        defer cli.deinit();
        try cli.helloCli("");
        const rows = try cli.listSessions();
        defer alloc.free(rows);
        try testing.expectEqual(@as(usize, 1), rows.len);
        var hex: [SessionId.len]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            rows[0].id[0],
            rows[0].id[1],
            rows[0].id[2],
            rows[0].id[3],
        }) catch unreachable;
        try testing.expectEqualStrings(id_str, &hex);
        try testing.expectEqual(@intFromEnum(session.State.attached), rows[0].state);
    }

    // Kill it by id; the child dies and the list empties.
    {
        var cli = try Client.connect(alloc, path);
        defer cli.deinit();
        try cli.helloCli(id_str);
        try cli.killSession();
    }
    try testing.expect(srv.manager.get(sid) == null);
    c1.deinit();

    // Latch exit-when-empty: with zero sessions the loop stops.
    {
        var cli = try Client.connect(alloc, path);
        defer cli.deinit();
        try cli.helloCli("");
        try cli.setExitWhenEmpty(true);
    }
    try testing.expect(srv.stopRequested());

    thread.join();
}

test "daemon harness: fake bridge event changes session state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const tmp = testing.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(alloc, "{s}/wraith-p24hs-{d}/ctl.sock", .{ tmp, linux.getpid() });
    defer alloc.free(path);

    var srv = try @import("server.zig").Server.init(alloc, testing.io, testing.environ, path);
    defer srv.deinit();

    // Harness socket is 0600 like the control socket.
    try testing.expectEqual(@as(u16, 0o600), (try @import("socket.zig").modeOf(alloc, srv.harness_path)) & 0o777);

    const Server = @import("server.zig").Server;
    const Pump = struct {
        fn run(s: *Server) void {
            // One control conn (create) + one harness conn (events).
            const fd = s.acceptFd() catch return;
            const t = std.Thread.spawn(.{}, Server.serveFd, .{ s, fd }) catch {
                _ = linux.close(fd);
                return;
            };
            s.acceptHarnessOnce() catch {};
            t.join();
        }
    };
    const thread = try std.Thread.spawn(.{}, Pump.run, .{&srv});

    // Create a session; the child must see the harness env.
    var c1 = try Client.connect(alloc, path);
    const snap1 = try c1.hello("");
    c1.freePayloads(snap1.payloads);
    const sid = srv.last_id.?;
    var id_buf: [SessionId.len]u8 = undefined;
    const id_str = sid.toString(&id_buf);

    // Env injection proof: the child's /proc environ carries both vars.
    {
        const child_pid = srv.live.getPtr(sid.bytes).?.pty.pid;
        var env_buf: [8192]u8 = undefined;
        var proc_path: [64]u8 = undefined;
        const env_path = try std.fmt.bufPrint(&proc_path, "/proc/{d}/environ", .{child_pid});
        var f = try std.Io.Dir.cwd().openFile(testing.io, env_path, .{});
        defer f.close(testing.io);
        // /proc environ has unknown length: accumulate short reads.
        var env_data: std.ArrayList(u8) = .empty;
        defer env_data.deinit(alloc);
        var r = f.reader(testing.io, &env_buf);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try env_data.appendSlice(alloc, chunk[0..n]);
        }
        try testing.expect(std.mem.indexOf(u8, env_data.items, "WRAITH_HARNESS_SOCK=") != null);
        var sock_var: [256]u8 = undefined;
        const want_sock = try std.fmt.bufPrint(
            &sock_var,
            "WRAITH_HARNESS_SOCK={s}",
            .{srv.harness_path},
        );
        try testing.expect(std.mem.indexOf(u8, env_data.items, want_sock) != null);
        var sess_var: [64]u8 = undefined;
        const want_sess = try std.fmt.bufPrint(&sess_var, "WRAITH_SESSION_ID={s}", .{id_str});
        try testing.expect(std.mem.indexOf(u8, env_data.items, want_sess) != null);
    }

    // Fake bridge: connect to the harness socket and write events.
    {
        const fd: linux.socket_t = syscall(linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
            0,
        )) catch return error.SocketFailed;
        defer _ = linux.close(fd);
        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        if (srv.harness_path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..srv.harness_path.len], srv.harness_path);
        addr.path[srv.harness_path.len] = 0;
        _ = syscall(linux.connect(
            fd,
            @ptrCast(&addr),
            @intCast(@offsetOf(linux.sockaddr.un, "path") + srv.harness_path.len + 1),
        )) catch return error.ConnectFailed;
        var ev_buf: [256]u8 = undefined;
        const ev1 = try std.fmt.bufPrint(
            &ev_buf,
            "{{\"v\":1,\"type\":\"state\",\"state\":\"executing_tool\",\"tool\":\"edit\",\"session_id\":\"{s}\"}}\n",
            .{id_str},
        );
        _ = linux.write(fd, ev1.ptr, ev1.len);
        // Garbage + unknown-session lines must not disturb the session.
        _ = linux.write(fd, "not json\n", "not json\n".len);
        const unknown_sess = "{\"v\":1,\"type\":\"state\",\"state\":\"idle\",\"session_id\":\"00000000\"}\n";
        _ = linux.write(fd, unknown_sess.ptr, unknown_sess.len);
        const ev2 = try std.fmt.bufPrint(
            &ev_buf,
            "{{\"v\":1,\"type\":\"state\",\"state\":\"awaiting_approval\",\"session_id\":\"{s}\"}}\n",
            .{id_str},
        );
        _ = linux.write(fd, ev2.ptr, ev2.len);
    }

    // The pump thread ingests until the bridge closes; poll for it.
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        const hs = srv.live.getPtr(sid.bytes).?.harness;
        if (hs.state == .awaiting_approval and hs.tool() == null) break;
        std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
    }
    {
        const hs = srv.live.getPtr(sid.bytes).?.harness;
        try testing.expectEqual(@import("harness_event.zig").State.awaiting_approval, hs.state);
        try testing.expect(hs.tool() == null);
    }

    c1.deinit();
    thread.join();
}

test "daemon harness: query merges tier1 and tier2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const tmp = testing.environ.getPosix("TMPDIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(alloc, "{s}/wraith-p27q-{d}/ctl.sock", .{ tmp, linux.getpid() });
    defer alloc.free(path);

    var srv = try @import("server.zig").Server.init(alloc, testing.io, testing.environ, path);
    defer srv.deinit();

    // Two sequential control conns: create, then query.
    const ServeTwo = struct {
        fn run(s: *@import("server.zig").Server) void {
            s.acceptOnce() catch {};
            s.acceptOnce() catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, ServeTwo.run, .{&srv});

    var c1 = try Client.connect(alloc, path);
    const snap1 = try c1.hello("");
    c1.freePayloads(snap1.payloads);
    const sid = srv.last_id.?;
    var id_buf: [SessionId.len]u8 = undefined;
    const id_str = sid.toString(&id_buf);
    c1.deinit();

    // Tier 1 via direct ingest (the socket path is covered by the
    // P2.4 test); the child runs `sleep`, so Tier 2 stays false.
    srv.ingestHarnessEvent(.{ .state = .executing_tool, .tool = "edit", .session_id = id_str });

    var cli = try Client.connect(alloc, path);
    try cli.helloCli("");
    const rows = try cli.queryHarnesses();
    defer alloc.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(sid.bytes, rows[0].id);
    try testing.expectEqual(@intFromEnum(@import("harness_event.zig").State.executing_tool), rows[0].tier1);
    try testing.expectEqual(@as(u8, 0), rows[0].tier2);
    try testing.expectEqual(@as(u8, 4), rows[0].tool_len);
    try testing.expectEqualStrings("edit", rows[0].tool[0..4]);
    cli.deinit();

    thread.join();
}

fn gridContains(term: *Terminal, needle: []const u8) bool {
    var y: u16 = 0;
    while (y < term.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < term.cols) : (x += 1) {
            if (gridCodepoint(term, x, y) != needle[0]) continue;
            var ok = true;
            var k: usize = 0;
            while (k < needle.len) : (k += 1) {
                if (x + k >= term.cols or
                    gridCodepoint(term, @intCast(x + k), y) != needle[k])
                {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
    }
    return false;
}

fn gridCodepoint(term: *const Terminal, x: u16, y: u16) u21 {
    const cell = term.screens.active.pages
        .getCell(.{ .active = .{ .x = x, .y = y } }) orelse return 0;
    return switch (cell.cell.content_tag) {
        .codepoint, .codepoint_grapheme => cell.cell.content.codepoint.data,
        else => 0,
    };
}
