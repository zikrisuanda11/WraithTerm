//! SSP extension payloads (P4.8): remote images + harness telemetry.
//!
//! - `ImageChunk` (D1 remote): the client stores its file locally;
//!   the REMOTE path travels chunked; the remote host writes it to
//!   its own paste dir and pastes the remote path. Reassembly here
//!   joins chunks by `(image_id)`; the caller verifies bytes (hash)
//!   and routes through `image_store`.
//! - `Telemetry` (D6 remote): harness JSON-lines events forwarded
//!   over SSP. Ordering per session is by arrival; the daemon feeds
//!   them to the same `ingestHarnessEvent` path as local bridges.
//!
//! Both ride the P4.1/P4.2 sealed-fragment transport as single codec
//! frames (like P4.4 snapshots): encode → fragment → seal → send.
const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const crypto = @import("ssp_crypto.zig");
const frag = @import("ssp_frag.zig");
const link = @import("ssp_link.zig");
const sync = @import("ssp_sync.zig");

/// Reassembled image: id + mime + full bytes (owned).
pub const Image = struct {
    image_id: u16,
    mime: codec.MimeTag,
    bytes: []u8,
};

/// Joins `ImageChunk` frames into whole images. One instance per
/// receiver; keyed by image_id. Out-of-order and duplicated chunks
/// are fine; mismatched counts for one id drop the partial.
pub const ImageAssembler = struct {
    alloc: Allocator,
    partials: std.AutoHashMap(u16, Partial),

    const Partial = struct {
        count: u16,
        mime: codec.MimeTag,
        parts: []?[]u8,
        got: u32 = 0,
        bytes: usize = 0,
    };

    pub fn init(alloc: Allocator) ImageAssembler {
        return .{ .alloc = alloc, .partials = .init(alloc) };
    }

    pub fn deinit(self: *ImageAssembler) void {
        var it = self.partials.valueIterator();
        while (it.next()) |p| self.freePartial(p);
        self.partials.deinit();
        self.* = undefined;
    }

    fn freePartial(self: *ImageAssembler, p: *Partial) void {
        for (p.parts) |slot| if (slot) |s| self.alloc.free(s);
        self.alloc.free(p.parts);
    }

    /// Feed one decoded `ImageChunk`. Returns the completed image
    /// (owned bytes) when its last chunk arrives, else null.
    pub fn feed(self: *ImageAssembler, chunk: codec.ImageChunk) !?Image {
        if (chunk.chunk_count == 0 or chunk.chunk_index >= chunk.chunk_count) return null;
        const gop = try self.partials.getOrPut(chunk.image_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .count = chunk.chunk_count,
                .mime = chunk.mime,
                .parts = try self.alloc.alloc(?[]u8, chunk.chunk_count),
            };
            @memset(gop.value_ptr.parts, null);
        }
        const p = gop.value_ptr;
        if (p.count != chunk.chunk_count or p.mime != chunk.mime) {
            self.freePartial(p);
            _ = self.partials.remove(chunk.image_id);
            return null;
        }
        if (p.parts[chunk.chunk_index] != null) return null;
        p.parts[chunk.chunk_index] = try self.alloc.dupe(u8, chunk.data);
        p.bytes += chunk.data.len;
        p.got += 1;
        if (p.got != p.count) return null;
        const bytes = try self.alloc.alloc(u8, p.bytes);
        errdefer self.alloc.free(bytes);
        var off: usize = 0;
        for (p.parts) |slot| {
            const s = slot.?;
            @memcpy(bytes[off..][0..s.len], s);
            off += s.len;
        }
        const img = Image{ .image_id = chunk.image_id, .mime = chunk.mime, .bytes = bytes };
        self.freePartial(p);
        _ = self.partials.remove(chunk.image_id);
        return img;
    }
};

/// Ordered telemetry sink: records event payloads in arrival order
/// with their origin session. The daemon routes each to
/// `ingestHarnessEvent` (same as local bridge lines).
pub const TelemetryLog = struct {
    alloc: Allocator,
    events: std.ArrayList(Entry),

    pub const Entry = struct {
        origin_session_id: u32,
        event: []u8,
    };

    pub fn init(alloc: Allocator) TelemetryLog {
        return .{ .alloc = alloc, .events = .empty };
    }

    pub fn deinit(self: *TelemetryLog) void {
        for (self.events.items) |*e| self.alloc.free(e.event);
        self.events.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn record(self: *TelemetryLog, msg: codec.Telemetry) !void {
        try self.events.append(self.alloc, .{
            .origin_session_id = msg.origin_session_id,
            .event = try self.alloc.dupe(u8, msg.event),
        });
    }
};

/// Send one codec frame over the sealed-fragment transport (shared
/// by image chunks and telemetry).
pub fn sendFrame(
    alloc: Allocator,
    tx: link.Transport,
    sealer: *crypto.Sealer,
    msg: codec.Message,
    msg_id: u32,
) !void {
    const frame = try codec.encode(alloc, msg);
    defer alloc.free(frame);
    const max_plain = tx.maxDatagramSize() -| (crypto.header_len + crypto.tag_length);
    const chunks = try frag.fragment(alloc, msg_id, frame, max_plain);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    var pkt: [link.max_datagram]u8 = undefined;
    for (chunks) |c| {
        const sealed = try sealer.seal(&pkt, c, 0);
        try tx.send(sealed);
    }
}

test "ext: image chunks join out of order, dups ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var asmb = ImageAssembler.init(alloc);
    defer asmb.deinit();
    var data: [3000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 17 + 5) % 251);
    // 3 chunks of 1000.
    const c0 = codec.ImageChunk{ .image_id = 9, .chunk_index = 0, .chunk_count = 3, .mime = .png, .data = data[0..1000] };
    const c1 = codec.ImageChunk{ .image_id = 9, .chunk_index = 1, .chunk_count = 3, .mime = .png, .data = data[1000..2000] };
    const c2 = codec.ImageChunk{ .image_id = 9, .chunk_index = 2, .chunk_count = 3, .mime = .png, .data = data[2000..3000] };
    try testing.expect(try asmb.feed(c2) == null);
    try testing.expect(try asmb.feed(c2) == null);
    try testing.expect(try asmb.feed(c0) == null);
    const img = (try asmb.feed(c1)) orelse return error.TestUnexpectedResult;
    defer alloc.free(img.bytes);
    try testing.expectEqual(@as(u16, 9), img.image_id);
    try testing.expectEqual(codec.MimeTag.png, img.mime);
    try testing.expectEqualSlices(u8, &data, img.bytes);
    // Bad index rejected.
    const bad = codec.ImageChunk{ .image_id = 9, .chunk_index = 9, .chunk_count = 3, .mime = .png, .data = "" };
    try testing.expect(try asmb.feed(bad) == null);
}

test "ext: telemetry log preserves order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var log = TelemetryLog.init(alloc);
    defer log.deinit();
    try log.record(.{ .event = "{\"state\":\"thinking\"}", .origin_session_id = 1 });
    try log.record(.{ .event = "{\"state\":\"executing_tool\"}", .origin_session_id = 1 });
    try log.record(.{ .event = "{\"state\":\"idle\"}", .origin_session_id = 2 });
    try testing.expectEqual(@as(usize, 3), log.events.items.len);
    try testing.expectEqualStrings("{\"state\":\"thinking\"}", log.events.items[0].event);
    try testing.expectEqual(@as(u32, 2), log.events.items[2].origin_session_id);
}

// P4.8 acceptance: a 64 KiB image (chunked ImageChunk frames) plus
// three telemetry events travel the sealed-fragment LossyLink
// (loss 15% + dup + reorder); the image reassembles hash-identical
// and events arrive in order. Retransmission here is a test-local
// resend loop (P4.5 owns the real one).
test "ext: e2e image hash plus event order over lossy link" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lb = link.Loopback.init(alloc);
    defer lb.deinit();
    var up = link.LossyLink.init(alloc, lb.endpoint(.a), 0xE7, .{
        .loss = 0.15,
        .duplicate = 0.05,
        .reorder = 0.2,
    });
    defer up.deinit();
    var down = link.LossyLink.init(alloc, lb.endpoint(.b), 0xE8, .{});
    defer down.deinit();
    const tx = up.transport();
    const rx = down.transport();

    const key: [crypto.key_length]u8 = .{0x48} ** crypto.key_length;
    var sealer = crypto.Sealer{ .key = key, .dir = .client_to_server };
    var opener = crypto.Opener{ .key = key, .dir = .client_to_server };
    var re = frag.Reassembler.init(alloc);
    defer re.deinit();
    var images = ImageAssembler.init(alloc);
    defer images.deinit();
    var tlog = TelemetryLog.init(alloc);
    defer tlog.deinit();

    // 64 KiB pseudo-PNG (real magic + pattern body).
    var img: [65536]u8 = undefined;
    img[0], img[1], img[2], img[3] = .{ 0x89, 0x50, 0x4E, 0x47 };
    img[4], img[5], img[6], img[7] = .{ 0x0D, 0x0A, 0x1A, 0x0A };
    for (img[8..], 0..) |*b, i| b.* = @intCast((i * 41 + 11) % 251);
    var want_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&img, &want_hash, .{});

    // Split into ImageChunk codec frames (8 KiB data each).
    const per: usize = 8192;
    const n_chunks: u16 = @intCast((img.len + per - 1) / per);
    var msg_id: u32 = 100;
    var ci: u16 = 0;
    while (ci < n_chunks) : (ci += 1) {
        const start = @as(usize, ci) * per;
        const end = @min(start + per, img.len);
        try sendFrame(alloc, tx, &sealer, .{ .image_chunk = .{
            .image_id = 3,
            .chunk_index = ci,
            .chunk_count = n_chunks,
            .mime = .png,
            .data = img[start..end],
        } }, msg_id);
        msg_id += 1;
    }
    // Three telemetry events as single frames.
    const events = [_][]const u8{
        "{\"v\":1,\"type\":\"state\",\"state\":\"thinking\",\"session_id\":\"abc\"}",
        "{\"v\":1,\"type\":\"state\",\"state\":\"executing_tool\",\"tool\":\"edit\",\"session_id\":\"abc\"}",
        "{\"v\":1,\"type\":\"state\",\"state\":\"idle\",\"session_id\":\"abc\"}",
    };
    for (events) |ev| {
        try sendFrame(alloc, tx, &sealer, .{ .telemetry = .{
            .event = ev,
            .origin_session_id = 7,
        } }, msg_id);
        msg_id += 1;
    }

    // Phase 1: image with resend rounds until hash-complete.
    var got_img: ?Image = null;
    defer if (got_img) |im| alloc.free(im.bytes);
    var rbuf: [link.max_datagram]u8 = undefined;
    var obuf: [link.max_datagram]u8 = undefined;
    var round: usize = 0;
    while (got_img == null and round < 30) : (round += 1) {
        // Resend everything (test-local reliability).
        ci = 0;
        while (ci < n_chunks) : (ci += 1) {
            const start = @as(usize, ci) * per;
            const end = @min(start + per, img.len);
            // New msg_ids per resend (fresh fragments).
            try sendFrame(alloc, tx, &sealer, .{ .image_chunk = .{
                .image_id = 3,
                .chunk_index = ci,
                .chunk_count = n_chunks,
                .mime = .png,
                .data = img[start..end],
            } }, 1000 + @as(u32, @intCast(round * 100)) + ci);
        }
        var step: usize = 0;
        while (step < 300) : (step += 1) {
            up.advance(1000);
            down.advance(1000);
            up.pump();
            down.pump();
            while (rx.recv(&rbuf, 0)) |dg| {
                const plain = opener.open(&obuf, dg) catch continue;
                if (try re.feed(plain, down.now_ns)) |blob| {
                    defer alloc.free(blob);
                    const msgs = try sync.splitFrames(alloc, blob);
                    defer alloc.free(msgs);
                    for (msgs) |m| switch (m) {
                        .image_chunk => |c| {
                            if (try images.feed(c)) |im| {
                                if (got_img) |old| alloc.free(old.bytes);
                                got_img = im;
                            }
                        },
                        else => {},
                    };
                }
            } else |_| {}
            _ = re.sweep(down.now_ns);
            if (got_img != null) break;
        }
    }
    try testing.expect(got_img != null);
    var got_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(got_img.?.bytes, &got_hash, .{});
    try testing.expectEqualSlices(u8, &want_hash, &got_hash);

    // Phase 2: telemetry stop-and-wait — each event is resent until
    // recorded before the next is sent, so arrival order is send
    // order even under reorder.
    for (events) |ev| {
        const before = tlog.events.items.len;
        var eround: usize = 0;
        while (tlog.events.items.len == before and eround < 30) : (eround += 1) {
            try sendFrame(alloc, tx, &sealer, .{ .telemetry = .{
                .event = ev,
                .origin_session_id = 7,
            } }, 5000 + @as(u32, @intCast(eround)));
            var step: usize = 0;
            while (step < 200 and tlog.events.items.len == before) : (step += 1) {
                up.advance(1000);
                down.advance(1000);
                up.pump();
                down.pump();
                while (rx.recv(&rbuf, 0)) |dg| {
                    const plain = opener.open(&obuf, dg) catch continue;
                    if (try re.feed(plain, down.now_ns)) |blob| {
                        defer alloc.free(blob);
                        const msgs = try sync.splitFrames(alloc, blob);
                        defer alloc.free(msgs);
                        for (msgs) |m| switch (m) {
                            .telemetry => |t| try tlog.record(t),
                            else => {},
                        };
                    }
                } else |_| {}
                _ = re.sweep(down.now_ns);
            }
        }
        try testing.expectEqual(before + 1, tlog.events.items.len);
    }
    try testing.expect(std.mem.indexOf(u8, tlog.events.items[0].event, "thinking") != null);
    try testing.expect(std.mem.indexOf(u8, tlog.events.items[1].event, "executing_tool") != null);
    try testing.expect(std.mem.indexOf(u8, tlog.events.items[2].event, "idle") != null);
    try testing.expectEqual(@as(u32, 7), tlog.events.items[2].origin_session_id);
}
