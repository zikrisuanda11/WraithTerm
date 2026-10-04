//! SSP datagram transport: interface + test doubles (P4.2).
//!
//! Follows `ARCHITECTURE.md` §3 (designed P0.6), implemented under
//! `src/daemon/` (not `src/remote/` — that directory was never
//! created; daemon modules are the established convention).
//!
//! - `Transport`: datagram interface (send/recv/maxDatagramSize).
//! - `Loopback`: in-memory endpoint pair, no syscalls.
//! - `LossyLink`: wraps a `Transport`, injects loss/duplicate/
//!   delay/reorder deterministically (seeded PRNG, virtual clock).
//!   The official AC2.5 test method (§0.7 bans `tc netem`).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest SSP datagram on the wire (D9).
pub const max_datagram: usize = 1200;

pub const SendError = Allocator.Error || error{ PeerGone, TooLarge };
pub const RecvError = error{ Timeout, Closed };

/// Datagram-oriented unreliable transport (ARCHITECTURE §3.1).
/// NOT thread-safe; the owner serializes calls.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, datagram: []const u8) SendError!void,
        recv: *const fn (ptr: *anyopaque, buf: []u8, timeout_ns: u64) RecvError![]u8,
        maxDatagramSize: *const fn (ptr: *anyopaque) usize,
    };

    pub fn send(self: Transport, datagram: []const u8) SendError!void {
        return self.vtable.send(self.ptr, datagram);
    }

    pub fn recv(self: Transport, buf: []u8, timeout_ns: u64) RecvError![]u8 {
        return self.vtable.recv(self.ptr, buf, timeout_ns);
    }

    pub fn maxDatagramSize(self: Transport) usize {
        return self.vtable.maxDatagramSize(self.ptr);
    }
};

/// In-memory endpoint pair. `pair.a` and `pair.b` are connected:
/// `a.send` is readable via `b.recv` and vice versa. Queues are
/// bounded (4096); overflow drops the oldest (never OOMs the test).
pub const Loopback = struct {
    alloc: Allocator,
    ato_b: std.ArrayList([]u8),
    bto_a: std.ArrayList([]u8),
    closed: bool = false,
    boxes: std.ArrayList(*anyopaque),

    const capacity = 4096;

    pub fn init(alloc: Allocator) Loopback {
        return .{
            .alloc = alloc,
            .ato_b = .empty,
            .bto_a = .empty,
            .boxes = .empty,
        };
    }

    pub fn deinit(self: *Loopback) void {
        for (self.ato_b.items) |d| self.alloc.free(d);
        for (self.bto_a.items) |d| self.alloc.free(d);
        self.ato_b.deinit(self.alloc);
        self.bto_a.deinit(self.alloc);
        for (self.boxes.items) |b| {
            const box: *Box = @ptrCast(@alignCast(b));
            self.alloc.destroy(box);
        }
        self.boxes.deinit(self.alloc);
        self.* = undefined;
    }

    pub const End = enum { a, b };

    const Box = struct {
        link: *Loopback,
        end: End,
    };

    pub fn endpoint(self: *Loopback, end: End) Transport {
        const box = self.alloc.create(Box) catch unreachable;
        // Tracked in `boxes`, freed by `deinit` alongside the queues.
        self.boxes.append(self.alloc, box) catch unreachable;
        box.* = .{ .link = self, .end = end };
        return .{
            .ptr = box,
            .vtable = &.{
                .send = struct {
                    fn f(ptr: *anyopaque, datagram: []const u8) SendError!void {
                        const b: *Box = @ptrCast(@alignCast(ptr));
                        return b.link.rawSend(b.end, datagram);
                    }
                }.f,
                .recv = struct {
                    fn f(ptr: *anyopaque, buf: []u8, timeout_ns: u64) RecvError![]u8 {
                        const b: *Box = @ptrCast(@alignCast(ptr));
                        return b.link.rawRecv(b.end, buf, timeout_ns);
                    }
                }.f,
                .maxDatagramSize = struct {
                    fn f(ptr: *anyopaque) usize {
                        _ = ptr;
                        return max_datagram;
                    }
                }.f,
            },
        };
    }

    fn outQueue(self: *Loopback, end: End) *std.ArrayList([]u8) {
        return switch (end) {
            .a => &self.ato_b,
            .b => &self.bto_a,
        };
    }

    fn rawSend(self: *Loopback, from: End, datagram: []const u8) SendError!void {
        if (self.closed) return error.PeerGone;
        if (datagram.len > max_datagram) return error.TooLarge;
        const q = self.outQueue(from);
        if (q.items.len >= capacity) {
            const old = q.orderedRemove(0);
            self.alloc.free(old);
        }
        q.append(self.alloc, try self.alloc.dupe(u8, datagram)) catch return error.PeerGone;
    }

    fn rawRecv(self: *Loopback, end: End, buf: []u8, timeout_ns: u64) RecvError![]u8 {
        _ = timeout_ns;
        if (self.closed) return error.Closed;
        // `end` receives what the OTHER side sent.
        const q = switch (end) {
            .a => &self.bto_a,
            .b => &self.ato_b,
        };
        if (q.items.len == 0) return error.Timeout;
        const d = q.orderedRemove(0);
        defer self.alloc.free(d);
        if (d.len > buf.len) return error.Timeout;
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
};

/// Deterministic lossy wrapper (ARCHITECTURE §3.3, AC2.5 method).
/// One instance per direction, each with its own PRNG stream.
/// Time is virtual (`now_ns`, advanced manually): no real sleeps,
/// fully deterministic given the seed.
pub const LossyLink = struct {
    alloc: Allocator,
    inner: Transport,
    rng: std.Random.DefaultPrng,
    cfg: Config,
    now_ns: u64 = 0,
    pending: std.ArrayList(Scheduled),

    pub const Config = struct {
        loss: f32 = 0.0,
        duplicate: f32 = 0.0,
        delay_ns: u64 = 0,
        delay_jitter_ns: u64 = 0,
        reorder: f32 = 0.0,
        max_queue: usize = 4096,
    };

    const Scheduled = struct {
        due_ns: u64,
        data: []u8,
    };

    pub fn init(alloc: Allocator, inner: Transport, seed: u64, cfg: Config) LossyLink {
        return .{
            .alloc = alloc,
            .inner = inner,
            .rng = std.Random.DefaultPrng.init(seed),
            .cfg = cfg,
            .pending = .empty,
        };
    }

    pub fn deinit(self: *LossyLink) void {
        for (self.pending.items) |s| self.alloc.free(s.data);
        self.pending.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn transport(self: *LossyLink) Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = struct {
                    fn f(ptr: *anyopaque, datagram: []const u8) SendError!void {
                        const l: *LossyLink = @ptrCast(@alignCast(ptr));
                        return l.send(datagram);
                    }
                }.f,
                .recv = struct {
                    fn f(ptr: *anyopaque, buf: []u8, timeout_ns: u64) RecvError![]u8 {
                        const l: *LossyLink = @ptrCast(@alignCast(ptr));
                        return l.recv(buf, timeout_ns);
                    }
                }.f,
                .maxDatagramSize = struct {
                    fn f(ptr: *anyopaque) usize {
                        const l: *LossyLink = @ptrCast(@alignCast(ptr));
                        return l.inner.maxDatagramSize();
                    }
                }.f,
            },
        };
    }

    fn roll(self: *LossyLink, p: f32) bool {
        if (p <= 0) return false;
        if (p >= 1) return true;
        return self.rng.random().float(f32) < p;
    }

    pub fn send(self: *LossyLink, datagram: []const u8) SendError!void {
        // Release anything whose delay expired first, so delay only
        // ever postpones (never strands) delivery.
        self.flushDue();
        if (self.roll(self.cfg.loss)) return;
        const copies: usize = if (self.roll(self.cfg.duplicate)) 2 else 1;
        var i: usize = 0;
        while (i < copies) : (i += 1) {
            var jitter: u64 = 0;
            if (self.cfg.delay_jitter_ns > 0) {
                jitter = self.rng.random().uintLessThan(u64, self.cfg.delay_jitter_ns + 1);
            }
            const due = self.now_ns + self.cfg.delay_ns + jitter;
            const data = try self.alloc.dupe(u8, datagram);
            errdefer self.alloc.free(data);
            if (self.pending.items.len >= self.cfg.max_queue) {
                const old = self.pending.orderedRemove(0);
                self.alloc.free(old.data);
            }
            // Reorder: insert at a random position instead of the
            // tail, so arrival order differs from send order.
            if (self.roll(self.cfg.reorder) and self.pending.items.len > 0) {
                const at = self.rng.random().uintLessThan(usize, self.pending.items.len + 1);
                try self.pending.insert(self.alloc, at, .{ .due_ns = due, .data = data });
            } else {
                try self.pending.append(self.alloc, .{ .due_ns = due, .data = data });
            }
        }
        self.flushDue();
    }

    /// Forward due packets to the inner transport, in queue order.
    fn flushDue(self: *LossyLink) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].due_ns > self.now_ns) {
                i += 1;
                continue;
            }
            const s = self.pending.orderedRemove(i);
            defer self.alloc.free(s.data);
            self.inner.send(s.data) catch {
                // Inner full/gone: drop (lossy by definition).
            };
        }
    }

    pub fn recv(self: *LossyLink, buf: []u8, timeout_ns: u64) RecvError![]u8 {
        // Pumping the sender side too: a test that only receives
        // still releases expired delays.
        self.flushDue();
        return self.inner.recv(buf, timeout_ns);
    }

    /// Release expired delays to the inner transport. Owners call
    /// this after `advance` (tests) or on every loop tick (daemons)
    /// so delayed packets cannot strand behind an idle link.
    pub fn pump(self: *LossyLink) void {
        self.flushDue();
    }

    /// Advance the virtual clock (tests only).
    pub fn advance(self: *LossyLink, delta_ns: u64) void {
        self.now_ns += delta_ns;
    }
};

test "link: loopback delivers intact" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lb = Loopback.init(alloc);
    defer lb.deinit();
    const a = lb.endpoint(.a);
    const b = lb.endpoint(.b);
    try testing.expectEqual(max_datagram, a.maxDatagramSize());
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Timeout, b.recv(&buf, 0));
    try a.send("hello");
    try testing.expectEqualStrings("hello", try b.recv(&buf, 0));
    try testing.expectError(error.Timeout, b.recv(&buf, 0));
    // Direction isolation.
    try b.send("back");
    try testing.expectEqualStrings("back", try a.recv(&buf, 0));
    try testing.expectError(error.Timeout, a.recv(&buf, 0));
}

test "link: lossless passthrough is transparent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lb = Loopback.init(alloc);
    defer lb.deinit();
    var lossy = LossyLink.init(alloc, lb.endpoint(.a), 0x5EED, .{});
    defer lossy.deinit();
    var plain = LossyLink.init(alloc, lb.endpoint(.b), 0x5EEF, .{});
    defer plain.deinit();
    const tx = lossy.transport();
    const rx = plain.transport();
    var buf: [64]u8 = undefined;
    try tx.send("abc");
    try testing.expectEqualStrings("abc", try rx.recv(&buf, 0));
}

test "link: total loss drops everything" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lb = Loopback.init(alloc);
    defer lb.deinit();
    var lossy = LossyLink.init(alloc, lb.endpoint(.a), 1, .{ .loss = 1.0 });
    defer lossy.deinit();
    const t = lossy.transport();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) try t.send("x");
    try testing.expectError(error.Timeout, t.recv(&buf, 0));
}

test "link: delay holds until clock advances" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lb = Loopback.init(alloc);
    defer lb.deinit();
    var lossy = LossyLink.init(alloc, lb.endpoint(.a), 2, .{ .delay_ns = 1_000_000 });
    defer lossy.deinit();
    var plain = LossyLink.init(alloc, lb.endpoint(.b), 3, .{});
    defer plain.deinit();
    const tx = lossy.transport();
    const rx = plain.transport();
    var buf: [64]u8 = undefined;
    try tx.send("late");
    try testing.expectError(error.Timeout, rx.recv(&buf, 0));
    lossy.advance(999_999);
    try testing.expectError(error.Timeout, rx.recv(&buf, 0));
    lossy.advance(1);
    lossy.pump();
    try testing.expectEqualStrings("late", try rx.recv(&buf, 0));
}

test "link: duplicate and reorder observable, deterministic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Same seed twice → identical arrival sequence.
    var first: [10][]u8 = undefined;
    var second: [10][]u8 = undefined;
    var first_n: usize = 0;
    var second_n: usize = 0;
    var run: usize = 0;
    while (run < 2) : (run += 1) {
        var lb = Loopback.init(alloc);
        defer lb.deinit();
        var up = LossyLink.init(alloc, lb.endpoint(.a), 0x1234, .{
            .duplicate = 0.5,
            .reorder = 0.5,
        });
        defer up.deinit();
        var down = LossyLink.init(alloc, lb.endpoint(.b), 0x5678, .{});
        defer down.deinit();
        const tx = up.transport();
        const rx = down.transport();
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var msg: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&msg, "p{d}", .{i});
            try tx.send(s);
        }
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        while (rx.recv(&buf, 0)) |d| {
            (if (run == 0) &first else &second)[n] = try alloc.dupe(u8, d);
            n += 1;
            if (n == 10) break;
        } else |_| {}
        try testing.expect(n > 0);
        if (run == 0) first_n = n else second_n = n;
    }
    defer {
        for (first[0..first_n]) |d| alloc.free(d);
        for (second[0..second_n]) |d| alloc.free(d);
    }
    try testing.expectEqual(first_n, second_n);
    for (first[0..first_n], second[0..second_n]) |a, b| try testing.expectEqualStrings(a, b);
}
