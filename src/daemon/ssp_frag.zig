//! SSP fragmentation + reassembly (P4.2, D9).
//!
//! Messages larger than one datagram (≤ 1200 B) split into chunks;
//! the chunk header (`[u32 msg_id][u16 index][u16 count]`) travels
//! INSIDE the AEAD plaintext (PROTOCOL: reassembly timeout 5 s,
//! total cap 4 MiB; over-cap fragments are dropped, never crash).
//!
//! Pure over caller buffers; time is an injected `now_ns` (virtual
//! in tests, real on the wire). One `Reassembler` per receiver.
const std = @import("std");
const Allocator = std.mem.Allocator;
const link = @import("ssp_link.zig");

/// Chunk header inside the AEAD plaintext.
pub const header_len = 8;
/// Reassembly timeout (D9: 5 s).
pub const timeout_ns: u64 = 5 * std.time.ns_per_s;
/// Total cap across partial messages (D9: 4 MiB).
pub const max_total_bytes: usize = 4 * 1024 * 1024;

/// Split `payload` into chunk plaintexts (header + slice). Each
/// chunk fits `max_datagram` bytes of PLAINTEXT; the caller seals
/// each chunk (P4.1) before sending. Returns owned list; each entry
/// is separately owned.
pub fn fragment(
    alloc: Allocator,
    msg_id: u32,
    payload: []const u8,
    max_datagram: usize,
) ![][]u8 {
    const per = max_datagram -| header_len;
    if (per == 0) return error.DatagramTooSmall;
    const count = (payload.len + per - 1) / per;
    if (count > std.math.maxInt(u16)) return error.MessageTooLarge;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c);
        out.deinit(alloc);
    }
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const start = @as(usize, i) * per;
        const end = @min(start + per, payload.len);
        const chunk = try alloc.alloc(u8, header_len + (end - start));
        std.mem.writeInt(u32, chunk[0..4], msg_id, .little);
        std.mem.writeInt(u16, chunk[4..6], i, .little);
        std.mem.writeInt(u16, chunk[6..8], @intCast(count), .little);
        @memcpy(chunk[header_len..], payload[start..end]);
        try out.append(alloc, chunk);
    }
    return out.toOwnedSlice(alloc);
}

pub const FeedError = Allocator.Error || error{MessageTooLarge};

/// One receiver's partial-message table.
pub const Reassembler = struct {
    alloc: Allocator,
    partials: std.AutoHashMap(u32, Partial),
    total_bytes: usize = 0,

    const Partial = struct {
        count: u16,
        got: u32 = 0,
        parts: []?[]u8,
        bytes: usize = 0,
        deadline_ns: u64,
    };

    pub fn init(alloc: Allocator) Reassembler {
        return .{ .alloc = alloc, .partials = .init(alloc) };
    }

    pub fn deinit(self: *Reassembler) void {
        var it = self.partials.valueIterator();
        while (it.next()) |p| self.freePartial(p);
        self.partials.deinit();
        self.* = undefined;
    }

    fn freePartial(self: *Reassembler, p: *Partial) void {
        for (p.parts) |slot| if (slot) |s| self.alloc.free(s);
        self.alloc.free(p.parts);
    }

    /// Feed one opened (decrypted) chunk. Returns the assembled
    /// message (owned) when the last missing chunk arrives, else
    /// null. Duplicates are freed and ignored. Over-cap messages are
    /// dropped whole (`error.MessageTooLarge`, partial freed).
    pub fn feed(
        self: *Reassembler,
        chunk: []const u8,
        now_ns: u64,
    ) FeedError!?[]u8 {
        if (chunk.len < header_len) return null;
        const msg_id = std.mem.readInt(u32, chunk[0..4], .little);
        const index = std.mem.readInt(u16, chunk[4..6], .little);
        const count = std.mem.readInt(u16, chunk[6..8], .little);
        if (count == 0 or index >= count) return null;
        const body = chunk[header_len..];

        const gop = try self.partials.getOrPut(msg_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .count = count,
                .parts = try self.alloc.alloc(?[]u8, count),
                .deadline_ns = now_ns +| timeout_ns,
            };
            @memset(gop.value_ptr.parts, null);
        }
        const p = gop.value_ptr;
        if (p.count != count) return null;
        if (p.parts[index] != null) return null;
        if (self.total_bytes + body.len > max_total_bytes) {
            self.freePartial(p);
            _ = self.partials.remove(msg_id);
            self.recount();
            return error.MessageTooLarge;
        }
        p.parts[index] = try self.alloc.dupe(u8, body);
        p.bytes += body.len;
        self.total_bytes += body.len;
        p.got += 1;
        if (p.got != p.count) return null;
        // Complete: join in order.
        const msg = try self.alloc.alloc(u8, p.bytes);
        errdefer self.alloc.free(msg);
        var off: usize = 0;
        for (p.parts) |slot| {
            const s = slot.?;
            @memcpy(msg[off..][0..s.len], s);
            off += s.len;
        }
        self.freePartial(p);
        _ = self.partials.remove(msg_id);
        self.recount();
        return msg;
    }

    fn recount(self: *Reassembler) void {
        var total: usize = 0;
        var it = self.partials.valueIterator();
        while (it.next()) |p| total += p.bytes;
        self.total_bytes = total;
    }

    /// Drop expired partials. Returns the number evicted.
    pub fn sweep(self: *Reassembler, now_ns: u64) usize {
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(self.alloc);
        var it = self.partials.iterator();
        while (it.next()) |kv| {
            if (now_ns >= kv.value_ptr.deadline_ns) {
                dead.append(self.alloc, kv.key_ptr.*) catch break;
            }
        }
        for (dead.items) |id| {
            if (self.partials.fetchRemove(id)) |kv| {
                var p = kv.value;
                self.freePartial(&p);
            }
        }
        if (dead.items.len > 0) self.recount();
        return dead.items.len;
    }
};

test "frag: split and join sizes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var msg: [5000]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @intCast(i % 251);
    const chunks = try fragment(alloc, 7, &msg, 1200);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    // 5000 B / (1200-8) → 5 chunks; headers carry id/index/count.
    try testing.expectEqual(@as(usize, 5), chunks.len);
    for (chunks, 0..) |c, i| {
        try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, c[0..4], .little));
        try testing.expectEqual(@as(u16, @intCast(i)), std.mem.readInt(u16, c[4..6], .little));
        try testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, c[6..8], .little));
    }
    var re = Reassembler.init(alloc);
    defer re.deinit();
    // Out-of-order feed still joins.
    const order = [_]usize{ 4, 1, 3, 0, 2 };
    var done: ?[]u8 = null;
    for (order) |i| {
        if (try re.feed(chunks[i], 0)) |m| done = m;
    }
    defer if (done) |m| alloc.free(m);
    try testing.expect(done != null);
    try testing.expectEqualSlices(u8, &msg, done.?);
}

test "frag: duplicates ignored, timeout evicts" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var msg: [3000]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @intCast(i % 251);
    const chunks = try fragment(alloc, 9, &msg, 1200);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    var re = Reassembler.init(alloc);
    defer re.deinit();
    try testing.expect(try re.feed(chunks[0], 0) == null);
    // Duplicate of chunk 0: ignored, still incomplete.
    try testing.expect(try re.feed(chunks[0], 1) == null);
    // Never completes: sweep after the 5 s timeout evicts it.
    try testing.expectEqual(@as(usize, 0), re.sweep(1_000_000_000));
    try testing.expectEqual(@as(usize, 1), re.sweep(timeout_ns + 2));
    // Late chunk for the evicted message starts a NEW partial.
    try testing.expect(try re.feed(chunks[1], timeout_ns + 3) == null);
    try testing.expectEqual(@as(usize, 1), re.sweep(timeout_ns * 2 + 4));
}

// P4.2 acceptance: fragment → seal (P4.1) → LossyLink loopback →
// open → reassemble, deterministic across seeds, under loss +
// reorder + duplication. A test-local resend loop (P4.5 will own
// retransmission) covers dropped chunks: resealed chunks carry new
// AEAD seqs, and the reassembler dedups by chunk index.
test "frag: e2e over lossy link, deterministic seeds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const crypto = @import("ssp_crypto.zig");
    const seeds = [_]u64{ 1, 7, 42, 0x5EED, 999 };
    for (seeds) |seed| {
        var lb = link.Loopback.init(alloc);
        defer lb.deinit();
        // One LossyLink per direction (ARCHITECTURE §3.4).
        var up = link.LossyLink.init(alloc, lb.endpoint(.a), seed, .{
            .loss = 0.2,
            .duplicate = 0.05,
            .reorder = 0.2,
        });
        defer up.deinit();
        var down = link.LossyLink.init(alloc, lb.endpoint(.b), seed ^ 0x9E37, .{});
        defer down.deinit();
        const tx = up.transport();
        const rx = down.transport();

        const key: [crypto.key_length]u8 = .{0x33} ** crypto.key_length;
        var sealer = crypto.Sealer{ .key = key, .dir = .client_to_server };
        var opener = crypto.Opener{ .key = key, .dir = .client_to_server };
        var re = Reassembler.init(alloc);
        defer re.deinit();

        var msg: [8000]u8 = undefined;
        for (&msg, 0..) |*b, i| b.* = @intCast((i * 31 + 7) % 251);
        const chunks = try fragment(alloc, 0xCAFE, &msg, 1000);
        defer {
            for (chunks) |c| alloc.free(c);
            alloc.free(chunks);
        }
        var got: ?[]u8 = null;
        defer if (got) |m| alloc.free(m);
        var rbuf: [1200]u8 = undefined;
        var obuf: [1200]u8 = undefined;
        var round: usize = 0;
        while (got == null and round < 20) : (round += 1) {
            for (chunks) |c| {
                var pkt: [1200]u8 = undefined;
                const sealed = try sealer.seal(&pkt, c, 0);
                try tx.send(sealed);
            }
            var step: usize = 0;
            while (got == null and step < 200) : (step += 1) {
                up.advance(1000);
                down.advance(1000);
                up.pump();
                down.pump();
                while (rx.recv(&rbuf, 0)) |d| {
                    const plain = opener.open(&obuf, d) catch continue;
                    if (try re.feed(plain, down.now_ns)) |m| {
                        got = m;
                        break;
                    }
                } else |_| {}
                _ = re.sweep(down.now_ns);
            }
        }
        try testing.expect(got != null);
        try testing.expectEqualSlices(u8, &msg, got.?);
    }
}
