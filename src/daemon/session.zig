//! WraithTerm session manager (P1.3).
//!
//! Owns the daemon-side session table: create/list/kill by `SessionId`
//! (D8) plus scrollback memory accounting with a per-session cap. This
//! module owns no PTY or terminal state yet (that arrives in P1.4); it
//! tracks the metadata every session needs and enforces the memory
//! budget P1.5's chunked snapshot/scollback restore will live under.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SessionId = @import("id.zig").SessionId;

/// Default cap on sessions per daemon. The daemon is single-user (D8);
/// this only bounds bookkeeping, not PTY count (P1.4 enforces its own).
pub const default_max_sessions: usize = 64;

/// Default scrollback budget per session in bytes (D4 restores up to
/// `wraith-scrollback-lines`, default 10000; at ~a few hundred bytes per
/// row worst case this is generous headroom).
pub const default_max_scrollback_bytes: usize = 4 * 1024 * 1024;

/// Lifecycle state of one session.
pub const State = enum {
    /// Running with no interactive client attached.
    detached,
    /// Exactly one interactive client attached (D8).
    attached,
    /// Kill requested; child reaping/PTY teardown pending (P1.4).
    closing,
};

/// One daemon-owned session (metadata only in P1.3).
pub const Session = struct {
    id: SessionId,
    state: State = .detached,
    /// Scrollback bytes currently held for this session.
    scrollback_bytes: usize = 0,
    /// Monotonic state id for snapshot/diff ack tracking (PROTOCOL §4.2).
    state_id: u32 = 0,
    /// Creation timestamp (unix ms) for TTL/LRU decisions.
    created_ms: i64 = 0,
};

pub const Error = error{
    /// Table already holds `max_sessions` sessions.
    TooManySessions,
    /// No session with this ID.
    NoSuchSession,
    /// `scrollback_bytes` would exceed the per-session budget.
    BudgetExceeded,
};

/// Owns all sessions. Not thread-safe; the daemon serializes calls.
pub const Manager = struct {
    alloc: Allocator,
    sessions: std.AutoHashMap([4]u8, Session),
    max_sessions: usize,
    max_scrollback_bytes: usize,

    /// Create a session with a fresh random ID. Collisions retry; with a
    /// 32-bit ID space needing 16 retries is a bug, so cap them.
    pub fn init(
        alloc: Allocator,
        max_sessions: usize,
        max_scrollback_bytes: usize,
    ) Manager {
        return .{
            .alloc = alloc,
            .sessions = std.AutoHashMap([4]u8, Session).init(alloc),
            .max_sessions = max_sessions,
            .max_scrollback_bytes = max_scrollback_bytes,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.sessions.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Manager) usize {
        return self.sessions.count();
    }

    /// Total scrollback bytes held across all sessions.
    pub fn totalScrollback(self: *const Manager) usize {
        var total: usize = 0;
        var it = self.sessions.valueIterator();
        while (it.next()) |s| total += s.scrollback_bytes;
        return total;
    }

    /// Create a session with a fresh random ID. Collisions retry; with a
    /// 32-bit ID space needing 16 retries is a bug, so cap them.
    pub fn create(
        self: *Manager,
        io: std.Io,
        now_ms: i64,
    ) (Error || Allocator.Error)!SessionId {
        if (self.sessions.count() >= self.max_sessions)
            return error.TooManySessions;
        var tries: usize = 0;
        while (tries < 16) : (tries += 1) {
            const id = SessionId.generate(io);
            if (self.sessions.contains(id.bytes)) continue;
            try self.sessions.put(id.bytes, .{
                .id = id,
                .created_ms = now_ms,
            });
            return id;
        }
        return error.TooManySessions;
    }

    pub fn get(self: *const Manager, id: SessionId) ?Session {
        return self.sessions.get(id.bytes);
    }

    fn getPtr(self: *Manager, id: SessionId) Error!*Session {
        return self.sessions.getPtr(id.bytes) orelse
            return error.NoSuchSession;
    }

    /// Attach a client. A second attach takes over (D8/AC1.4): the
    /// previous client is told `Detached(taken_over)` by the IPC layer
    /// (P1.6/P1.7); the manager just records the new state.
    pub fn attach(self: *Manager, id: SessionId) Error!bool {
        const s = try self.getPtr(id);
        const took_over = s.state == .attached;
        s.state = .attached;
        return took_over;
    }

    pub fn detach(self: *Manager, id: SessionId) Error!void {
        const s = try self.getPtr(id);
        if (s.state == .attached) s.state = .detached;
    }

    /// Account scrollback growth. Fails without mutating on over-budget.
    pub fn growScrollback(
        self: *Manager,
        id: SessionId,
        bytes: usize,
    ) Error!void {
        const s = try self.getPtr(id);
        const next, _ = @addWithOverflow(s.scrollback_bytes, bytes);
        if (next > self.max_scrollback_bytes) return error.BudgetExceeded;
        s.scrollback_bytes = next;
    }

    pub fn shrinkScrollback(
        self: *Manager,
        id: SessionId,
        bytes: usize,
    ) Error!void {
        const s = try self.getPtr(id);
        s.scrollback_bytes = s.scrollback_bytes -| bytes;
    }

    /// Bump the snapshot/diff state id, returning the new value.
    pub fn nextStateId(self: *Manager, id: SessionId) Error!u32 {
        const s = try self.getPtr(id);
        s.state_id +%= 1;
        return s.state_id;
    }

    /// Remove a session. Unknown IDs are `NoSuchSession` (the IPC layer
    /// maps this to `Error{code=NoSuchSession}`, PROTOCOL §4.12).
    pub fn kill(self: *Manager, id: SessionId) Error!void {
        if (!self.sessions.remove(id.bytes)) return error.NoSuchSession;
    }
};

test "session: create/get/list basics" {
    const testing = std.testing;
    var m = Manager.init(testing.allocator, 4, 1024);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.count());

    const a = try m.create(testing.io, 1000);
    const b = try m.create(testing.io, 2000);
    try testing.expect(!a.eql(b));
    try testing.expectEqual(@as(usize, 2), m.count());

    const got = m.get(a).?;
    try testing.expectEqual(State.detached, got.state);
    try testing.expectEqual(@as(i64, 1000), got.created_ms);
    try testing.expect(m.get(SessionId{ .bytes = .{ 0, 0, 0, 0 } }) == null);
}

test "session: attach/detach/takeover" {
    const testing = std.testing;
    var m = Manager.init(testing.allocator, 4, 1024);
    defer m.deinit();
    const id = try m.create(testing.io, 0);

    try testing.expectEqual(false, try m.attach(id));
    try testing.expectEqual(State.attached, m.get(id).?.state);
    // Second attach takes over.
    try testing.expectEqual(true, try m.attach(id));
    try m.detach(id);
    try testing.expectEqual(State.detached, m.get(id).?.state);
    // Detach when already detached is a no-op.
    try m.detach(id);

    try testing.expectError(
        error.NoSuchSession,
        m.attach(SessionId{ .bytes = .{ 9, 9, 9, 9 } }),
    );
}

test "session: kill removes and frees the slot" {
    const testing = std.testing;
    var m = Manager.init(testing.allocator, 1, 1024);
    defer m.deinit();
    const id = try m.create(testing.io, 0);
    try m.kill(id);
    try testing.expectEqual(@as(usize, 0), m.count());
    try testing.expectError(error.NoSuchSession, m.kill(id));
    // The slot is reusable.
    _ = try m.create(testing.io, 0);
    try testing.expectError(error.TooManySessions, m.create(testing.io, 0));
}

test "session: scrollback budget enforced" {
    const testing = std.testing;
    var m = Manager.init(testing.allocator, 4, 100);
    defer m.deinit();
    const id = try m.create(testing.io, 0);

    try m.growScrollback(id, 60);
    try m.growScrollback(id, 40);
    try testing.expectEqual(@as(usize, 100), m.totalScrollback());
    // Over-budget growth fails and does not mutate.
    try testing.expectError(error.BudgetExceeded, m.growScrollback(id, 1));
    try testing.expectEqual(@as(usize, 100), m.get(id).?.scrollback_bytes);
    // Shrink saturates at zero.
    try m.shrinkScrollback(id, 1000);
    try testing.expectEqual(@as(usize, 0), m.get(id).?.scrollback_bytes);
    try testing.expectError(
        error.NoSuchSession,
        m.growScrollback(SessionId{ .bytes = .{ 1, 2, 3, 4 } }, 1),
    );
}

test "session: state ids increase monotonically" {
    const testing = std.testing;
    var m = Manager.init(testing.allocator, 4, 1024);
    defer m.deinit();
    const id = try m.create(testing.io, 0);
    try testing.expectEqual(@as(u32, 1), try m.nextStateId(id));
    try testing.expectEqual(@as(u32, 2), try m.nextStateId(id));
}
