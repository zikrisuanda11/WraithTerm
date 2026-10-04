//! Full-snapshot sync over SSP (P4.4, no diffs).
//!
//! Server: snapshot `take` → codec frames → one byte blob → fragment
//! (P4.2) → seal each chunk (P4.1) → send over a `Transport`.
//! Client: recv → open → reassemble → split frames → join snapshot
//! payloads → restore a `Terminal`. Retransmission is P4.5's job:
//! the sender emits once; the receiver pumps until complete.
//!
//! Pure over caller buffers except the terminal fixtures (tests).
const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const snapshot = @import("snapshot.zig");
const crypto = @import("ssp_crypto.zig");
const frag = @import("ssp_frag.zig");
const link = @import("ssp_link.zig");
const Terminal = @import("../terminal/Terminal.zig");

/// Split a concatenated frame blob into messages (all borrowing
/// `blob`). Malformed input errors; empty input yields zero.
pub fn splitFrames(alloc: Allocator, blob: []const u8) ![]codec.Message {
    var out: std.ArrayList(codec.Message) = .empty;
    errdefer out.deinit(alloc);
    var rest = blob;
    while (rest.len > 0) {
        if (rest.len < 4) return error.Truncated;
        const len = std.mem.readInt(u32, rest[0..4], .little);
        if (len < 2 or len > codec.max_message_len) return error.BadLength;
        if (rest.len < 4 + len) return error.Truncated;
        const msg = try codec.decode(rest[0 .. 4 + len]);
        try out.append(alloc, msg);
        rest = rest[4 + len ..];
    }
    return out.toOwnedSlice(alloc);
}

/// Server side: snapshot `term` and send it as sealed fragments.
/// `msg_id` names this snapshot for reassembly. One shot, no retry.
pub fn sendSnapshot(
    alloc: Allocator,
    tx: link.Transport,
    sealer: *crypto.Sealer,
    term: *const Terminal,
    state_id: u32,
    msg_id: u32,
) !void {
    var taken = try snapshot.take(alloc, term, state_id, 64 * 1024);
    defer taken.deinit(alloc);
    // Encode all frames into one blob.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(alloc);
    for (taken.messages) |m| {
        const frame = try codec.encode(alloc, m);
        defer alloc.free(frame);
        try blob.appendSlice(alloc, frame);
    }
    // Plaintext budget: sealed chunks (crypto header + tag) must fit
    // one datagram; oversize sends are dropped by the transport.
    const max_plain = tx.maxDatagramSize() -| (crypto.header_len + crypto.tag_length);
    const chunks = try frag.fragment(alloc, msg_id, blob.items, max_plain);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    var pkt: [link.max_datagram + 64]u8 = undefined;
    for (chunks) |c| {
        const sealed = try sealer.seal(&pkt, c, 0);
        try tx.send(sealed);
    }
}

/// Client side: pump until one full snapshot arrives, then restore
/// it. Returns the owned `Terminal`. `now_ns` feeds reassembly
/// timeouts (virtual in tests).
pub fn recvSnapshot(
    alloc: Allocator,
    io: std.Io,
    rx: link.Transport,
    opener: *crypto.Opener,
    re: *frag.Reassembler,
    now_ns: u64,
    max_steps: usize,
) !Terminal {
    var rbuf: [link.max_datagram + 64]u8 = undefined;
    var obuf: [link.max_datagram + 64]u8 = undefined;
    var step: usize = 0;
    while (step < max_steps) : (step += 1) {
        const d = rx.recv(&rbuf, 0) catch {
            _ = re.sweep(now_ns);
            continue;
        };
        const plain = opener.open(&obuf, d) catch continue;
        if (try re.feed(plain, now_ns)) |blob| {
            defer alloc.free(blob);
            const msgs = try splitFrames(alloc, blob);
            defer alloc.free(msgs);
            var payloads: std.ArrayList([]const u8) = .empty;
            defer payloads.deinit(alloc);
            for (msgs) |m| {
                if (m != .snapshot) return error.UnexpectedMessage;
                try payloads.append(alloc, m.snapshot.payload);
            }
            var decoded = try snapshot.restore(alloc, io, payloads.items, 1024);
            defer decoded.deinit(alloc);
            return decoded.toOwned();
        }
    }
    return error.Incomplete;
}

test "sync: splitFrames round trip and rejects" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const f1 = try codec.encode(alloc, .{ .ack = .{ .state_id = 1, .seq_lo = 2, .flags = 3 } });
    defer alloc.free(f1);
    const f2 = try codec.encode(alloc, .{ .control = .{ .command = .detach } });
    defer alloc.free(f2);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(alloc);
    try blob.appendSlice(alloc, f1);
    try blob.appendSlice(alloc, f2);
    const msgs = try splitFrames(alloc, blob.items);
    defer alloc.free(msgs);
    try testing.expectEqual(@as(usize, 2), msgs.len);
    try testing.expect(msgs[0] == .ack);
    try testing.expect(msgs[1] == .control);
    const empty = try splitFrames(alloc, &.{});
    defer alloc.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectError(error.Truncated, splitFrames(alloc, f1[0 .. f1.len - 1]));
}

test "sync: loopback screen equality" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Headless = @import("../terminal/headless_proto.zig").Headless;

    var h = try Headless.init(alloc, 40, 12);
    defer h.deinit();
    h.feed("\x1b[1;32mgreen-bold\x1b[0m plain\r\n");
    h.feed("\x1b[7;20Hplaced-cursor");
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        var line: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "row{d:0>2}-data\r\n", .{i});
        h.feed(text);
    }

    var lb = link.Loopback.init(alloc);
    defer lb.deinit();
    var up = link.LossyLink.init(alloc, lb.endpoint(.a), 11, .{});
    defer up.deinit();
    var down = link.LossyLink.init(alloc, lb.endpoint(.b), 22, .{});
    defer down.deinit();
    const key: [crypto.key_length]u8 = .{0x44} ** crypto.key_length;
    var sealer = crypto.Sealer{ .key = key, .dir = .server_to_client };
    var opener = crypto.Opener{ .key = key, .dir = .server_to_client };
    var re = frag.Reassembler.init(alloc);
    defer re.deinit();

    try sendSnapshot(alloc, up.transport(), &sealer, h.term, 7, 0xBEEF);
    up.pump();
    var restored = try recvSnapshot(
        alloc,
        testing.io,
        down.transport(),
        &opener,
        &re,
        0,
        500,
    );
    defer restored.deinit(alloc);

    // Screen equality: size, cursor, every visible cell.
    try testing.expectEqual(h.term.cols, restored.cols);
    try testing.expectEqual(h.term.rows, restored.rows);
    const sc = h.term.screens.active.cursor;
    const rc = restored.screens.active.cursor;
    try testing.expectEqual(sc.x, rc.x);
    try testing.expectEqual(sc.y, rc.y);
    var y: u16 = 0;
    while (y < h.term.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < h.term.cols) : (x += 1) {
            const a = h.term.screens.active.pages.getCell(.{ .active = .{ .x = x, .y = y } });
            const b = restored.screens.active.pages.getCell(.{ .active = .{ .x = x, .y = y } });
            try testing.expect(a != null and b != null);
            try testing.expectEqual(a.?.cell.content.codepoint.data, b.?.cell.content.codepoint.data);
        }
    }
}
