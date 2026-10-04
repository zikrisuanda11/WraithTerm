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
const codec = @import("codec.zig");
const session = @import("session.zig");
const SessionId = @import("id.zig").SessionId;
const DaemonPty = @import("pty.zig").DaemonPty;
const daemon_snapshot = @import("snapshot.zig");
const sock = @import("socket.zig");

/// A live session: metadata in `Manager`, owned PTY + optional
/// active client connection here.
const LiveSession = struct {
    pty: *DaemonPty,
    conn: ?linux.socket_t = null,
};

pub const Server = struct {
    alloc: Allocator,
    io: std.Io,
    manager: session.Manager,
    live: std.AutoHashMap([4]u8, LiveSession),
    listener: sock.Server,
    /// The session id created or attached by the last served
    /// connection (test hook; set on `hello`).
    last_id: ?SessionId = null,

    pub fn init(
        alloc: Allocator,
        io: std.Io,
        socket_path: []const u8,
    ) sock.ListenError!Server {
        return .{
            .alloc = alloc,
            .io = io,
            .manager = .init(alloc, 64, 4 * 1024 * 1024),
            .live = .init(alloc),
            .listener = try sock.Server.listen(alloc, socket_path),
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
                    if (h.id.len == 0) {
                        const id = try self.manager.create(self.io, nowMs(self.io));
                        errdefer self.manager.kill(id) catch {};
                        const argv = [_][:0]const u8{ "/bin/sh", "-c", "sleep 60" };
                        const pty = try DaemonPty.spawn(self.alloc, &argv, null, 80, 24);
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
                        sid = null;
                        return;
                    },
                    else => {},
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
