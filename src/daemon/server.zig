//! Daemon serving loop: one connection serves one session (P1.7).
//!
//! Wire protocol is the `codec` framing over the `socket` listener.
//! A connection starts with `hello` (empty id = create + spawn,
//! set id = attach), then `input`/`resize`/`control` messages until
//! EOF or `control{detach}`. `take_over` on attach notifies the
//! previous connection with `detached{taken_over}` (D8).
//!
//! Linux-only in v1, like the rest of `src/daemon`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const codec = @import("codec.zig");
const session = @import("session.zig");
const SessionId = @import("id.zig").SessionId;
const DaemonPty = @import("pty.zig").DaemonPty;
const daemon_snapshot = @import("snapshot.zig");
const sock = @import("socket.zig");
const harness = @import("harness_sock.zig");
const detect = @import("harness_detect.zig");
const hevent = @import("harness_event.zig");
const notify = @import("harness_notify.zig");

/// A live session: metadata in `Manager`, owned PTY + optional
/// active client connection here.
const LiveSession = struct {
    pty: *DaemonPty,
    conn: ?linux.socket_t = null,
    harness: harness.HarnessState = .{},
};

pub const Server = struct {
    alloc: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    manager: session.Manager,
    live: std.AutoHashMap([4]u8, LiveSession),
    listener: sock.Server,
    /// Harness event listener (D6): bridges write JSON-lines here.
    harness_listener: sock.Server,
    harness_path: []u8,
    /// The session id created or attached by the last served
    /// connection (test hook; set on `hello`).
    last_id: ?SessionId = null,
    /// Set by `Control{exit_when_empty, on=1}`: `run` returns once
    /// no sessions remain (D8: `--exit-when-empty`).
    exit_when_empty: bool = false,

    pub fn init(
        alloc: Allocator,
        io: std.Io,
        environ: std.process.Environ,
        socket_path: []const u8,
    ) sock.ListenError!Server {
        const daemon_id = SessionId.generate(io);
        var id_buf: [SessionId.len]u8 = undefined;
        const hpath = try harness.listenerPath(
            alloc,
            socket_path,
            daemon_id.toString(&id_buf),
        );
        errdefer alloc.free(hpath);
        return .{
            .alloc = alloc,
            .io = io,
            .environ = environ,
            .manager = .init(alloc, 64, 4 * 1024 * 1024),
            .live = .init(alloc),
            .listener = try sock.Server.listen(alloc, socket_path),
            .harness_listener = try sock.Server.listen(alloc, hpath),
            .harness_path = hpath,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.live.valueIterator();
        while (it.next()) |ls| {
            if (ls.conn) |c| _ = linux.close(c);
            ls.pty.kill();
            while (!ls.pty.pollExit()) std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
            ls.pty.deinit();
        }
        self.live.deinit();
        self.manager.deinit();
        self.listener.deinit();
        self.harness_listener.deinit();
        self.alloc.free(self.harness_path);
    }

    /// Accept one connection and serve it until EOF/detach.
    /// For tests without concurrent clients.
    pub fn acceptOnce(self: *Server) !void {
        const fd = try self.acceptFd();
        self.serveConn(fd) catch {};
        _ = linux.close(fd);
    }

    /// Accept one connection; the caller owns the fd and must
    /// `serveConn` (usually on its own thread) then close it.
    pub fn acceptFd(self: *Server) !linux.socket_t {
        return syscall(linux.accept(self.listener.fd, null, null));
    }

    pub fn serveFd(self: *Server, fd: linux.socket_t) void {
        self.serveConn(fd) catch {};
        _ = linux.close(fd);
    }

    /// How long `run` idles with zero sessions before exiting when
    /// `exit_when_empty` is set (D8: 10 seconds).
    pub const empty_idle_ns: u64 = 10 * std.time.ns_per_s;

    /// Serve connections one at a time until the exit latch fires.
    /// With `exit_when_empty`, the latch fires only after 10 idle
    /// seconds with zero sessions (D8) — a freshly started daemon
    /// with no sessions yet still serves. The `+daemon` CLI action
    /// runs this; tests drive `acceptFd` + `serveFd` directly for
    /// concurrency.
    pub fn run(self: *Server) void {
        var empty_since: ?std.Io.Timestamp = null;
        while (true) {
            if (self.exit_when_empty and self.manager.count() == 0) {
                const now = std.Io.Timestamp.now(self.io, .awake);
                if (empty_since == null) empty_since = now;
                if (empty_since.?.durationTo(now).toNanoseconds() >= empty_idle_ns) return;
            } else {
                empty_since = null;
            }
            // Poll the listener so the idle deadline fires even with
            // no incoming connections.
            var fds = [_]posix.pollfd{.{
                .fd = self.listener.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const n = posix.poll(&fds, 1000) catch continue;
            if (n == 0) continue;
            self.acceptOnce() catch {};
        }
    }

    pub fn stopRequested(self: *const Server) bool {
        return self.exit_when_empty and self.manager.count() == 0;
    }

    /// Accept one bridge connection on the harness socket and ingest
    /// its event lines until EOF. Unknown/absent session ids are
    /// skipped; malformed lines never fail the connection.
    pub fn acceptHarnessOnce(self: *Server) !void {
        const fd: linux.socket_t = try syscall(linux.accept(
            self.harness_listener.fd,
            null,
            null,
        ));
        defer _ = linux.close(fd);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var buf: [hevent.max_line_bytes + 1]u8 = undefined;
        while (true) {
            const n = harness.readLine(fd, &buf) catch continue;
            const line = n orelse return;
            switch (hevent.parseLine(arena.allocator(), buf[0..line])) {
                .ok => |ev| self.ingestHarnessEvent(ev),
                .skip => {},
            }
        }
    }

    /// Apply one bridge event to its session. Events without a
    /// parseable `session_id`, or for unknown sessions, are dropped.
    /// Entry into `awaiting_approval` fires a best-effort OS
    /// notification (P2.8: edge-triggered, never blocking).
    pub fn ingestHarnessEvent(self: *Server, ev: hevent.Event) void {
        if (ev.session_id.len == 0) return;
        const id = SessionId.parse(ev.session_id) catch return;
        if (self.live.getPtr(id.bytes)) |ls| {
            const prev = ls.harness.state;
            ls.harness.apply(ev);
            if (notify.shouldNotify(prev, ev.state)) {
                var title_buf: [128]u8 = undefined;
                var body_buf: [256]u8 = undefined;
                const m = notify.message(ev.session_id, ev.tool, &title_buf, &body_buf);
                notify.send(self.io, self.alloc, m.title, m.body);
            }
        }
    }

    fn serveConn(self: *Server, fd: linux.socket_t) !void {
        var sid: ?SessionId = null;
        defer {
            // Connection gone without an explicit detach: flip state
            // only. The child keeps running (AC1.1).
            if (sid) |id| {
                self.manager.detach(id) catch {};
                if (self.live.getPtr(id.bytes)) |ls| {
                    if (ls.conn == fd) ls.conn = null;
                }
            }
        }
        while (true) {
            var msg = readMessage(self.alloc, fd) catch return;
            defer msg.deinit();
            switch (msg.owned.msg) {
                .hello => |h| {
                    if (h.role == .cli) {
                        // Control-only CLI: no session is created or
                        // attached. A set id selects the target for a
                        // later `kill_session`; empty id scopes the
                        // connection to `list_sessions` /
                        // `exit_when_empty`.
                        if (h.id.len != 0) {
                            sid = SessionId.parse(h.id) catch {
                                try writeMessage(fd, self.alloc, .{ .@"error" = .{
                                    .code = .no_such_session,
                                    .message = "bad session id",
                                } });
                                continue;
                            };
                        }
                        try writeMessage(fd, self.alloc, .{ .ack = .{ .state_id = 0, .seq_lo = 0, .flags = 0 } });
                        continue;
                    }
                    if (h.id.len == 0) {
                        const id = try self.manager.create(self.io, nowMs(self.io));
                        errdefer self.manager.kill(id) catch {};
                        // Every child sees the harness socket + its own
                        // session id (D6); the bridge uses them to report
                        // state without knowing daemon internals.
                        var id_buf: [SessionId.len]u8 = undefined;
                        const id_str = id.toString(&id_buf);
                        var child_env = try self.environ.createMap(self.alloc);
                        defer child_env.deinit();
                        try child_env.put(harness.sock_env, self.harness_path);
                        try child_env.put(harness.session_env, id_str);
                        const argv = [_][:0]const u8{ "/bin/sh", "-c", "sleep 60" };
                        const pty = try DaemonPty.spawn(self.alloc, &argv, &child_env, 80, 24);
                        errdefer {
                            pty.kill();
                            pty.deinit();
                        }
                        try self.live.put(id.bytes, .{ .pty = pty, .conn = fd });
                        _ = try self.manager.attach(id);
                        sid = id;
                    } else {
                        const id = SessionId.parse(h.id) catch {
                            try writeMessage(fd, self.alloc, .{ .@"error" = .{
                                .code = .no_such_session,
                                .message = "bad session id",
                            } });
                            continue;
                        };
                        const took = self.manager.attach(id) catch {
                            try writeMessage(fd, self.alloc, .{ .@"error" = .{
                                .code = .no_such_session,
                                .message = "no such session",
                            } });
                            continue;
                        };
                        if (self.live.getPtr(id.bytes)) |ls| {
                            if (took) {
                                if (ls.conn) |old| {
                                    writeMessage(old, self.alloc, .{ .detached = .{
                                        .reason = .taken_over,
                                    } }) catch {};
                                }
                            }
                            ls.conn = fd;
                        } else continue;
                        sid = id;
                    }
                    self.last_id = sid;
                    try self.sendSnapshot(fd, sid.?);
                },
                .input => |in| {
                    const id = sid orelse continue;
                    if (self.live.getPtr(id.bytes)) |ls| {
                        ls.pty.writeInput(in.data) catch {};
                        // Pump once so a follow-up snapshot sees the input.
                        _ = ls.pty.pump(200 * std.time.ns_per_ms) catch {};
                    }
                },
                .resize => |r| {
                    const id = sid orelse continue;
                    if (self.live.getPtr(id.bytes)) |ls| {
                        ls.pty.resize(r.cols, r.rows) catch {};
                    }
                },
                .control => |c| switch (c.command) {
                    .request_snapshot => {
                        const id = sid orelse continue;
                        try self.sendSnapshot(fd, id);
                    },
                    .detach => {
                        const id = sid orelse return;
                        try self.manager.detach(id);
                        if (self.live.getPtr(id.bytes)) |ls| {
                            if (ls.conn == fd) ls.conn = null;
                        }
                        sid = null;
                        try writeMessage(fd, self.alloc, .{ .ack = .{ .state_id = 0, .seq_lo = 0, .flags = 0 } });
                        return;
                    },
                    .kill_session => {
                        const id = sid orelse return;
                        if (self.live.fetchRemove(id.bytes)) |kv| {
                            var ls = kv.value;
                            if (ls.conn) |cc| {
                                if (cc != fd) _ = linux.close(cc);
                            }
                            ls.pty.kill();
                            while (!ls.pty.pollExit()) std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
                            ls.pty.deinit();
                        }
                        self.manager.kill(id) catch {};
                        try writeMessage(fd, self.alloc, .{ .ack = .{ .state_id = 0, .seq_lo = 0, .flags = 0 } });
                        sid = null;
                        return;
                    },
                    .list_sessions => {
                        try self.sendSessionList(fd);
                    },
                    .query_harnesses => {
                        try self.sendHarnessList(fd);
                    },
                    .exit_when_empty => {
                        self.exit_when_empty = c.on != 0;
                        try writeMessage(fd, self.alloc, .{ .ack = .{ .state_id = 0, .seq_lo = 0, .flags = 0 } });
                    },
                    // Takeover is implicit on attach (D8); an explicit
                    // `take_over` control is accepted and ignored.
                    .take_over => {},
                },
                else => {},
            }
        }
    }

    fn sendSnapshot(self: *Server, fd: linux.socket_t, id: SessionId) !void {
        const ls = self.live.getPtr(id.bytes) orelse return error.NoSession;
        // Drain fresh output before encoding.
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const flowed = ls.pty.pump(20 * std.time.ns_per_ms) catch break;
            if (!flowed) break;
        }
        var taken = try daemon_snapshot.take(
            self.alloc,
            ls.pty.headless.term,
            try self.manager.nextStateId(id),
            daemon_snapshot.default_chunk_bytes,
        );
        defer taken.deinit(self.alloc);
        for (taken.messages) |m| {
            try writeMessage(fd, self.alloc, m);
        }
    }

    fn sendSessionList(self: *Server, fd: linux.socket_t) !void {
        const n = self.manager.count();
        const entries = try self.alloc.alloc(codec.SessionListEntry, n);
        defer self.alloc.free(entries);
        var it = self.manager.sessions.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            entries[i] = .{
                .id = kv.key_ptr.*,
                .state = @intFromEnum(kv.value_ptr.state),
            };
        }
        try writeMessage(fd, self.alloc, .{ .session_list = .{ .entries = entries } });
    }

    /// Tier 1 comes from live bridge state; Tier 2 from one `/proc`
    /// snapshot scored per session child pid (P2.2). A failed proc
    /// scan degrades to tier2=false rather than failing the query.
    fn sendHarnessList(self: *Server, fd: linux.socket_t) !void {
        const n = self.manager.count();
        const entries = try self.alloc.alloc(codec.HarnessListEntry, n);
        defer self.alloc.free(entries);
        var snapshot: []detect.Proc = &.{};
        var proc_dir: ?std.Io.Dir = null;
        if (std.Io.Dir.cwd().openDir(self.io, "/proc", .{ .iterate = true })) |d| {
            proc_dir = d;
        } else |_| {}
        defer if (proc_dir) |*d| d.close(self.io);
        if (proc_dir) |d| {
            snapshot = detect.readSnapshot(self.alloc, self.io, d) catch &.{};
        }
        defer {
            for (snapshot) |p| self.alloc.free(p.comm);
            if (snapshot.len > 0) self.alloc.free(snapshot);
        }
        var it = self.manager.sessions.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            var e = codec.HarnessListEntry{
                .id = kv.key_ptr.*,
                .tier1 = @intFromEnum(hevent.State.unknown),
                .tier2 = 0,
                .tool_len = 0,
            };
            if (self.live.getPtr(kv.key_ptr.*)) |ls| {
                e.tier1 = @intFromEnum(ls.harness.state);
                if (ls.harness.tool()) |t| {
                    const m = @min(t.len, codec.max_tool_len);
                    @memcpy(e.tool[0..m], t[0..m]);
                    e.tool_len = @intCast(m);
                }
                const child: u32 = @intCast(ls.pty.pid);
                if (detect.subtreeHasHarness(snapshot, child)) e.tier2 = 1;
            }
            entries[i] = e;
        }
        try writeMessage(fd, self.alloc, .{ .harness_list = .{ .entries = entries } });
    }
};

fn nowMs(io: std.Io) i64 {
    const t = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(t.toNanoseconds(), std.time.ns_per_ms));
}

fn syscall(rc: usize) error{Failed}!linux.socket_t {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed >= -4095) return error.Failed;
    return @intCast(rc);
}

/// Read one codec frame from `fd` (blocking). EOF → error.EndOfStream.
/// The returned message borrows `buf` (zero-copy decode); both are
/// freed together by `deinit`. Dupe anything needed before that.
pub const InMessage = struct {
    owned: codec.OwnedMessage,
    buf: []u8,
    alloc: Allocator,

    pub fn deinit(self: *InMessage) void {
        self.owned.deinit();
        self.alloc.free(self.buf);
        self.* = undefined;
    }
};

pub fn readMessage(alloc: Allocator, fd: linux.socket_t) !InMessage {
    var len_buf: [4]u8 = undefined;
    readFull(fd, &len_buf) catch return error.EndOfStream;
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len < 2 or len > codec.max_message_len) return error.BadFrame;
    const buf = try alloc.alloc(u8, 4 + len);
    errdefer alloc.free(buf);
    @memcpy(buf[0..4], &len_buf);
    readFull(fd, buf[4..]) catch {
        alloc.free(buf);
        return error.EndOfStream;
    };
    const msg = codec.decodeAlloc(alloc, buf) catch {
        alloc.free(buf);
        return error.BadFrame;
    };
    return .{ .owned = msg, .buf = buf, .alloc = alloc };
}

pub fn writeMessage(fd: linux.socket_t, alloc: Allocator, msg: codec.Message) !void {
    const enc = try codec.encode(alloc, msg);
    defer alloc.free(enc);
    writeFull(fd, enc) catch return error.WriteFailed;
}

fn readFull(fd: linux.socket_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf[off..].ptr, buf.len - off);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            const e: linux.E = @enumFromInt(-signed);
            if (e == .INTR) continue;
            return error.ReadFailed;
        }
        if (signed == 0) return error.EndOfStream;
        off += @intCast(signed);
    }
}

fn writeFull(fd: linux.socket_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.write(fd, buf[off..].ptr, buf.len - off);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            const e: linux.E = @enumFromInt(-signed);
            if (e == .INTR) continue;
            return error.WriteFailed;
        }
        if (signed == 0) return error.WriteFailed;
        off += @intCast(signed);
    }
}
