//! State-numbered diff sync + ack/retransmit (P4.5).
//!
//! On top of P4.4's full snapshots: the server renders changed rows
//! as cursor-addressed VT (SGR styles preserved through the client's
//! own parser), numbers each diff (`base` → `state`), and keeps
//! unacked diffs for retransmit. The client applies a diff only when
//! `base == current`, acks the new state, and ignores replays.
//! Everything rides the P4.1/P4.2 sealed-fragment transport.
//!
//! Wire form: one `codec Diff` frame per diff (spans = changed rows;
//! `glyphs` = VT bytes for `\x1b[{row};1H...` row writes,
//! `style_data` empty), sent exactly like a P4.4 snapshot blob
//! (single frame → fragment → seal → send).
const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const snapshot = @import("snapshot.zig");
const crypto = @import("ssp_crypto.zig");
const frag = @import("ssp_frag.zig");
const link = @import("ssp_link.zig");
const sync = @import("ssp_sync.zig");
const Terminal = @import("../terminal/Terminal.zig");
const TerminalStream = @import("../terminal/stream_terminal.zig").Stream;
const stylepkg = @import("../terminal/style.zig");

/// Render changed rows of `new_term` vs `base_term` (same size) as
/// cursor-addressed VT writes. Returns owned bytes; empty when
/// identical. Caller frames these as one `codec Diff` message.
pub fn renderRowDiff(
    alloc: Allocator,
    base_term: *const Terminal,
    new_term: *const Terminal,
) ![]u8 {
    std.debug.assert(base_term.cols == new_term.cols);
    std.debug.assert(base_term.rows == new_term.rows);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var y: u16 = 0;
    while (y < new_term.rows) : (y += 1) {
        if (rowEqual(base_term, new_term, y)) continue;
        try w.print("\x1b[{d};1H", .{y + 1});
        var cur_style: ?u32 = null;
        var x: u16 = 0;
        while (x < new_term.cols) : (x += 1) {
            const cell = getCell(new_term, x, y) orelse continue;
            const sid = cell.cell.style_id;
            if (cur_style == null or cur_style.? != @as(u32, @intCast(sid))) {
                cur_style = @intCast(sid);
                if (sid == stylepkg.default_id) {
                    try w.writeAll("\x1b[0m");
                } else {
                    const page = cell.node.page();
                    const style = page.styles.get(page.memory, sid).*;
                    try style.formatterVt().format(w);
                }
            }
            const cp: u21 = switch (cell.cell.content_tag) {
                .codepoint, .codepoint_grapheme => cell.cell.content.codepoint.data,
                else => ' ',
            };
            var cbuf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &cbuf);
            try w.writeAll(cbuf[0..n]);
        }
        try w.writeAll("\x1b[0m");
    }
    return out.toOwnedSlice();
}

const PageList = @import("../terminal/PageList.zig");

fn getCell(term: *const Terminal, x: u16, y: u16) ?PageList.Cell {
    return term.screens.active.pages.getCell(.{ .active = .{ .x = x, .y = y } });
}

fn cellsEqual(a: ?PageList.Cell, b: ?PageList.Cell) bool {
    if (a == null or b == null) return a == null and b == null;
    const ca: u21 = switch (a.?.cell.content_tag) {
        .codepoint, .codepoint_grapheme => a.?.cell.content.codepoint.data,
        else => ' ',
    };
    const cb: u21 = switch (b.?.cell.content_tag) {
        .codepoint, .codepoint_grapheme => b.?.cell.content.codepoint.data,
        else => ' ',
    };
    return ca == cb and a.?.cell.style_id == b.?.cell.style_id;
}

fn rowEqual(base_term: *const Terminal, new_term: *const Terminal, y: u16) bool {
    var x: u16 = 0;
    while (x < new_term.cols) : (x += 1) {
        if (!cellsEqual(getCell(base_term, x, y), getCell(new_term, x, y))) return false;
    }
    return true;
}

/// Server diff session: tracks acked vs sent states, owns the
/// shadow terminal (the last acked screen) for diffing.
pub const DiffServer = struct {
    alloc: Allocator,
    io: std.Io,
    /// Last state the client acked (starts at the snapshot state).
    acked: u32,
    /// Next state to assign.
    next: u32,
    /// Unacked diffs by state (for retransmit).
    inflight: std.AutoHashMap(u32, []u8),
    /// Shadow of the acked screen.
    shadow: Terminal,

    pub fn init(alloc: Allocator, io: std.Io, base: *const Terminal, state: u32) !DiffServer {
        return .{
            .alloc = alloc,
            .io = io,
            .acked = state,
            .next = state +% 1,
            .inflight = .init(alloc),
            .shadow = try cloneTerm(alloc, io, base),
        };
    }

    pub fn deinit(self: *DiffServer) void {
        var it = self.inflight.valueIterator();
        while (it.next()) |v| self.alloc.free(v.*);
        self.inflight.deinit();
        self.shadow.deinit(self.alloc);
        self.* = undefined;
    }

    /// Diff live `term` against the shadow; if different, store and
    /// return the wire bytes (owned) with the next state id. Returns
    /// null when nothing changed.
    pub fn makeDiff(
        self: *DiffServer,
        term: *const Terminal,
    ) !?struct { state: u32, wire: []u8 } {
        const vt = try renderRowDiff(self.alloc, &self.shadow, term);
        defer self.alloc.free(vt);
        if (vt.len == 0) return null;
        const state = self.next;
        self.next +%= 1;
        const span = codec.DiffSpan{
            .start_x = 0,
            .start_y = 0,
            .cell_count = 0,
            .glyphs = vt,
            .style_data = &.{},
        };
        const frame = try codec.encode(self.alloc, .{ .diff = .{
            .base_state_id = self.acked,
            .state_id = state,
            .spans = @ptrCast(@constCast(&[_]codec.DiffSpan{span})),
        } });
        errdefer self.alloc.free(frame);
        try self.inflight.put(state, try self.alloc.dupe(u8, frame));
        return .{ .state = state, .wire = frame };
    }

    /// Record a client ack: drop inflight ≤ acked, advance the shadow
    /// by feeding the acked diffs' VT in order. (Shadow update needs
    /// the stored frames; applied oldest-first.)
    pub fn onAck(self: *DiffServer, ack_state: u32, feed: *HeadlessFeed) !void {
        var s = self.acked +% 1;
        while (true) : (s +%= 1) {
            if (s -% self.acked > ack_state -% self.acked) break;
            const kv = self.inflight.fetchRemove(s) orelse continue;
            defer self.alloc.free(kv.value);
            try feed.applyDiffFrame(self.alloc, kv.value);
            self.acked = s;
            if (s == ack_state) break;
        }
    }

    /// Resend bytes for all unacked states (oldest first). Caller
    /// fragments/seals/sends each; ownership stays here.
    pub fn unacked(self: *DiffServer, alloc: Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer out.deinit(alloc);
        var s = self.acked +% 1;
        while (s != self.next) : (s +%= 1) {
            if (self.inflight.get(s)) |frame| try out.append(alloc, frame);
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Feeds diff VT into a terminal (client apply + server shadow).
/// Owns a `TerminalStream` bound to the terminal, like
/// `Headless.feed` does.
pub const HeadlessFeed = struct {
    stream: TerminalStream,

    pub fn init(alloc: Allocator, term: *Terminal) HeadlessFeed {
        return .{ .stream = TerminalStream.init(.{
            .allocator = alloc,
            .handler = .init(term),
            .continuation_max_bytes = 1024,
        }) };
    }

    pub fn applyDiffFrame(self: *HeadlessFeed, alloc: Allocator, frame: []const u8) !void {
        _ = alloc;
        const msg = try codec.decode(frame);
        if (msg != .diff) return error.UnexpectedMessage;
        for (msg.diff.spans) |span| {
            self.stream.nextSlice(span.glyphs);
        }
    }
};

/// Clone a terminal through snapshot bytes (exact copy).
fn cloneTerm(alloc: Allocator, io: std.Io, term: *const Terminal) !Terminal {
    var taken = try snapshot.take(alloc, term, 0, 64 * 1024);
    defer taken.deinit(alloc);
    const payloads = try alloc.alloc([]const u8, taken.messages.len);
    defer alloc.free(payloads);
    for (taken.messages, 0..) |m, i| payloads[i] = m.snapshot.payload;
    var decoded = try snapshot.restore(alloc, io, payloads, 1024);
    defer decoded.deinit(alloc);
    return decoded.toOwned();
}

/// Client diff session: current state + apply + ack generation.
pub const DiffClient = struct {
    current: u32,
    feed: HeadlessFeed,

    /// Apply one wire frame: only when `base == current`
    /// (gap → drop; the next snapshot/resend heals). Returns the new
    /// state to ack, or null when dropped.
    pub fn applyFrame(self: *DiffClient, alloc: Allocator, frame: []const u8) !?u32 {
        const msg = try codec.decode(frame);
        if (msg != .diff) return error.UnexpectedMessage;
        if (msg.diff.base_state_id != self.current) return null;
        try self.feed.applyDiffFrame(alloc, frame);
        self.current = msg.diff.state_id;
        return self.current;
    }
};

test "diff: identical screens render empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Headless = @import("../terminal/headless_proto.zig").Headless;
    var h = try Headless.init(alloc, 20, 8);
    defer h.deinit();
    h.feed("hello\r\n");
    var other = try cloneTerm(alloc, testing.io, h.term);
    defer other.deinit(alloc);
    const vt = try renderRowDiff(alloc, h.term, &other);
    defer alloc.free(vt);
    try testing.expectEqual(@as(usize, 0), vt.len);
}

test "diff: changed rows apply through the parser" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Headless = @import("../terminal/headless_proto.zig").Headless;
    var h = try Headless.init(alloc, 20, 8);
    defer h.deinit();
    h.feed("aaa\r\n");
    var other = try cloneTerm(alloc, testing.io, h.term);
    defer other.deinit(alloc);
    h.feed("\x1b[1;31mRED\x1b[0m\r\nbbb\r\n");
    const vt = try renderRowDiff(alloc, &other, h.term);
    defer alloc.free(vt);
    // Apply to the shadow through the real VT parser.
    var feed = HeadlessFeed.init(alloc, &other);
    feed.stream.nextSlice(vt);
    const vt2 = try renderRowDiff(alloc, &other, h.term);
    defer alloc.free(vt2);
    try testing.expectEqual(@as(usize, 0), vt2.len);
}

// P4.5 acceptance: scripted VT in steps, diffs over LossyLink at
// AC2.5 profiles (loss 10/20/30% + 5ms delay + 20ms jitter + 5% dup
// + 5% reorder), client applies + acks, server resends unacked;
// final screens identical across 20 seeds. Seeds derive from the
// loop index, so failures reproduce by seed number.
test "diff: e2e lossy 20 seeds identical screens" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const losses = [_]f32{ 0.10, 0.20, 0.30 };
    var s: usize = 0;
    while (s < 20) : (s += 1) {
        for (losses) |loss| {
            try runDiffScenario(alloc, testing.io, 0x1000 + s, loss);
        }
    }
}

fn runDiffScenario(alloc: Allocator, io: std.Io, seed: u64, loss: f32) !void {
    const testing = std.testing;
    const Headless = @import("../terminal/headless_proto.zig").Headless;
    // Both sides start from identical empty screens at state 100.
    var srv_h = try Headless.init(alloc, 40, 12);
    defer srv_h.deinit();
    var cli_h = try Headless.init(alloc, 40, 12);
    defer cli_h.deinit();

    var lb = link.Loopback.init(alloc);
    defer lb.deinit();
    var up = link.LossyLink.init(alloc, lb.endpoint(.a), seed, .{
        .loss = loss,
        .duplicate = 0.05,
        .delay_ns = 5_000_000,
        .delay_jitter_ns = 20_000_000,
        .reorder = 0.05,
    });
    defer up.deinit();
    var down = link.LossyLink.init(alloc, lb.endpoint(.b), seed ^ 0x5EED, .{});
    defer down.deinit();
    const srv_tx = up.transport();
    const cli_rx = down.transport();
    const cli_tx = down.transport();
    const srv_rx = up.transport();

    const key: [crypto.key_length]u8 = .{0x45} ** crypto.key_length;
    var s_seal = crypto.Sealer{ .key = key, .dir = .server_to_client };
    var c_open = crypto.Opener{ .key = key, .dir = .server_to_client };
    var c_seal = crypto.Sealer{ .key = key, .dir = .client_to_server };
    var s_open = crypto.Opener{ .key = key, .dir = .client_to_server };

    var srv = try DiffServer.init(alloc, io, srv_h.term, 100);
    defer srv.deinit();
    var shadow_feed = HeadlessFeed.init(alloc, &srv.shadow);
    var cli_feed = HeadlessFeed.init(alloc, cli_h.term);
    var cli = DiffClient{ .current = 100, .feed = cli_feed };

    var rbuf: [link.max_datagram]u8 = undefined;
    var obuf: [link.max_datagram]u8 = undefined;
    var step: usize = 0;
    while (step < 10) : (step += 1) {
        var script: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &script,
            "\x1b[1;3{d}mstep{d}\x1b[0m L{x:0>4}\r\n",
            .{ step % 7 + 1, step, step * 7919 + @as(usize, @intCast(seed & 0xFF)) },
        );
        srv_h.feed(text);
        if (try srv.makeDiff(srv_h.term)) |d| {
            defer alloc.free(d.wire);
            var pkt: [link.max_datagram]u8 = undefined;
            const sealed = try s_seal.seal(&pkt, d.wire, 0);
            try srv_tx.send(sealed);
        }
        up.advance(25_000_000);
        down.advance(25_000_000);
        up.pump();
        down.pump();
        // Client drains diffs and acks the newest applied state.
        var ack: ?u32 = null;
        var n: usize = 0;
        while (n < 64) : (n += 1) {
            const dg = cli_rx.recv(&rbuf, 0) catch break;
            const plain = c_open.open(&obuf, dg) catch continue;
            if (try cli.applyFrame(alloc, plain)) |st| ack = st;
        }
        if (ack) |a| {
            var abuf: [64]u8 = undefined;
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u32, tmp[0..4], a, .little);
            std.mem.writeInt(u32, tmp[4..8], 0, .little);
            const sealed = try c_seal.seal(&abuf, &tmp, 0);
            try cli_tx.send(sealed);
        }
        up.pump();
        down.pump();
        // Server drains acks, advances its shadow, resends unacked.
        var m: usize = 0;
        while (m < 16) : (m += 1) {
            const dg = srv_rx.recv(&rbuf, 0) catch break;
            const plain = s_open.open(&obuf, dg) catch continue;
            if (plain.len < 4) continue;
            try srv.onAck(std.mem.readInt(u32, plain[0..4], .little), &shadow_feed);
        }
        const resend = try srv.unacked(alloc);
        defer alloc.free(resend);
        for (resend) |frame| {
            var pkt: [link.max_datagram]u8 = undefined;
            const sealed = try s_seal.seal(&pkt, frame, 0);
            try srv_tx.send(sealed);
        }
        up.pump();
        down.pump();
    }
    // Drain: extra rounds with no new input until the client is
    // current or the budget expires.
    var drain: usize = 0;
    while (cli.current != srv.next -% 1 and drain < 30) : (drain += 1) {
        up.advance(25_000_000);
        down.advance(25_000_000);
        up.pump();
        down.pump();
        var ack: ?u32 = null;
        var n: usize = 0;
        while (n < 64) : (n += 1) {
            const dg = cli_rx.recv(&rbuf, 0) catch break;
            const plain = c_open.open(&obuf, dg) catch continue;
            if (try cli.applyFrame(alloc, plain)) |st| ack = st;
        }
        if (ack) |a| {
            var abuf: [64]u8 = undefined;
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u32, tmp[0..4], a, .little);
            std.mem.writeInt(u32, tmp[4..8], 0, .little);
            const sealed = try c_seal.seal(&abuf, &tmp, 0);
            try cli_tx.send(sealed);
        }
        up.pump();
        down.pump();
        var m: usize = 0;
        while (m < 16) : (m += 1) {
            const dg = srv_rx.recv(&rbuf, 0) catch break;
            const plain = s_open.open(&obuf, dg) catch continue;
            if (plain.len < 4) continue;
            try srv.onAck(std.mem.readInt(u32, plain[0..4], .little), &shadow_feed);
        }
        const resend = try srv.unacked(alloc);
        defer alloc.free(resend);
        for (resend) |frame| {
            var pkt: [link.max_datagram]u8 = undefined;
            const sealed = try s_seal.seal(&pkt, frame, 0);
            try srv_tx.send(sealed);
        }
        up.pump();
        down.pump();
    }
    try testing.expectEqual(srv.next -% 1, cli.current);
    // Screen equality: size + every codepoint and style.
    try testing.expectEqual(srv_h.term.cols, cli_h.term.cols);
    try testing.expectEqual(srv_h.term.rows, cli_h.term.rows);
    var y: u16 = 0;
    while (y < srv_h.term.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < srv_h.term.cols) : (x += 1) {
            try testing.expect(cellsEqual(
                getCell(srv_h.term, x, y),
                getCell(cli_h.term, x, y),
            ));
        }
    }
}

// P4.10 acceptance: long endurance — big styled output, a resize
// each way (via snapshot resync), a simulated 30 s gap, all under
// 30% loss + jitter + dup. 20 seeds; final screens identical.
test "diff: endurance 20 seeds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: usize = 0;
    while (s < 20) : (s += 1) {
        try runEnduranceScenario(alloc, testing.io, 0xE000 + s);
    }
}

fn runEnduranceScenario(alloc: Allocator, io: std.Io, seed: u64) !void {
    const testing = std.testing;
    const Headless = @import("../terminal/headless_proto.zig").Headless;
    var srv_h = try Headless.init(alloc, 40, 12);
    defer srv_h.deinit();
    var cli_h = try Headless.init(alloc, 40, 12);
    defer cli_h.deinit();

    var lb = link.Loopback.init(alloc);
    defer lb.deinit();
    var up = link.LossyLink.init(alloc, lb.endpoint(.a), seed, .{
        .loss = 0.30,
        .duplicate = 0.05,
        .delay_ns = 5_000_000,
        .delay_jitter_ns = 20_000_000,
        .reorder = 0.05,
    });
    defer up.deinit();
    var down = link.LossyLink.init(alloc, lb.endpoint(.b), seed ^ 0x5EED, .{});
    defer down.deinit();
    const srv_tx = up.transport();
    const cli_rx = down.transport();
    const cli_tx = down.transport();
    const srv_rx = up.transport();

    const key: [crypto.key_length]u8 = .{0x4A} ** crypto.key_length;
    var s_seal = crypto.Sealer{ .key = key, .dir = .server_to_client };
    var c_open = crypto.Opener{ .key = key, .dir = .server_to_client };
    var c_seal = crypto.Sealer{ .key = key, .dir = .client_to_server };
    var s_open = crypto.Opener{ .key = key, .dir = .client_to_server };
    var re = frag.Reassembler.init(alloc);
    defer re.deinit();

    const Cx = struct {
        srv_tx: link.Transport,
        cli_rx: link.Transport,
        cli_tx: link.Transport,
        srv_rx: link.Transport,
        up: *link.LossyLink,
        down: *link.LossyLink,
        s_seal: *crypto.Sealer,
        c_open: *crypto.Opener,
        c_seal: *crypto.Sealer,
        s_open: *crypto.Opener,
        re: *frag.Reassembler,
        alloc: Allocator,
        rbuf: [link.max_datagram]u8 = undefined,
        obuf: [link.max_datagram]u8 = undefined,

        fn pumpAll(c: *@This()) void {
            c.up.advance(25_000_000);
            c.down.advance(25_000_000);
            c.up.pump();
            c.down.pump();
        }

        fn sendDiff(c: *@This(), srv: *DiffServer, term: *Terminal) !void {
            if (try srv.makeDiff(term)) |d| {
                defer c.alloc.free(d.wire);
                var pkt: [link.max_datagram]u8 = undefined;
                const sealed = try c.s_seal.seal(&pkt, d.wire, 0);
                try c.srv_tx.send(sealed);
            }
        }

        fn drainClient(c: *@This(), cli: *DiffClient) !?u32 {
            var ack: ?u32 = null;
            var n: usize = 0;
            while (n < 128) : (n += 1) {
                const dg = c.cli_rx.recv(&c.rbuf, 0) catch break;
                const plain = c.c_open.open(&c.obuf, dg) catch continue;
                if (try cli.applyFrame(c.alloc, plain)) |st| ack = st;
            }
            return ack;
        }

        fn sendAck(c: *@This(), ack: u32) !void {
            var abuf: [64]u8 = undefined;
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u32, tmp[0..4], ack, .little);
            std.mem.writeInt(u32, tmp[4..8], 0, .little);
            const sealed = try c.c_seal.seal(&abuf, &tmp, 0);
            try c.cli_tx.send(sealed);
        }

        fn drainServer(c: *@This(), srv: *DiffServer, feed: *HeadlessFeed) !void {
            var m: usize = 0;
            while (m < 32) : (m += 1) {
                const dg = c.srv_rx.recv(&c.rbuf, 0) catch break;
                const plain = c.s_open.open(&c.obuf, dg) catch continue;
                if (plain.len < 4) continue;
                try srv.onAck(std.mem.readInt(u32, plain[0..4], .little), feed);
            }
        }

        fn resendUnacked(c: *@This(), srv: *DiffServer) !void {
            const resend = try srv.unacked(c.alloc);
            defer c.alloc.free(resend);
            for (resend) |frame| {
                var pkt: [link.max_datagram]u8 = undefined;
                const sealed = try c.s_seal.seal(&pkt, frame, 0);
                try c.srv_tx.send(sealed);
            }
            c.up.pump();
            c.down.pump();
        }

        fn stepDiffs(c: *@This(), srv: *DiffServer, cli: *DiffClient, srv_term: *Terminal) !void {
            try c.sendDiff(srv, srv_term);
            c.pumpAll();
            if (try c.drainClient(cli)) |a| try c.sendAck(a);
            c.up.pump();
            c.down.pump();
        }

        fn settle(c: *@This(), srv: *DiffServer, feed: *HeadlessFeed, cli: *DiffClient) !void {
            var i: usize = 0;
            while (cli.current != srv.next -% 1 and i < 60) : (i += 1) {
                c.pumpAll();
                if (try c.drainClient(cli)) |a| try c.sendAck(a);
                c.up.pump();
                c.down.pump();
                try c.drainServer(srv, feed);
                try c.resendUnacked(srv);
                c.up.pump();
                c.down.pump();
            }
        }

        /// Snapshot resync after a resize: the server snapshots at
        /// `state`; the client restores into its live terminal slot;
        /// both diff sides rebase to `state`. Sealed-fragment
        /// transport with resend rounds (same reliability as diffs).
        fn resync(
            c: *@This(),
            io: std.Io,
            srv_term: *Terminal,
            state: u32,
            srv: *DiffServer,
            cli: *DiffClient,
            cli_term_slot: *Terminal,
            shadow_feed: *HeadlessFeed,
            cli_feed: *HeadlessFeed,
        ) !void {
            var msg_id: u32 = 9000 +% state;
            var round: usize = 0;
            var done = false;
            while (!done and round < 30) : (round += 1) {
                try sync.sendSnapshot(c.alloc, c.srv_tx, c.s_seal, srv_term, state, msg_id);
                msg_id +%= 1;
                var step: usize = 0;
                while (step < 200 and !done) : (step += 1) {
                    c.pumpAll();
                    while (c.cli_rx.recv(&c.rbuf, 0)) |dg| {
                        const plain = c.c_open.open(&c.obuf, dg) catch continue;
                        if (try c.re.feed(plain, c.down.now_ns)) |blob| {
                            defer c.alloc.free(blob);
                            const msgs = try sync.splitFrames(c.alloc, blob);
                            defer c.alloc.free(msgs);
                            var payloads: std.ArrayList([]const u8) = .empty;
                            defer payloads.deinit(c.alloc);
                            for (msgs) |m| {
                                if (m != .snapshot) continue;
                                try payloads.append(c.alloc, m.snapshot.payload);
                            }
                            if (payloads.items.len == 0) continue;
                            var decoded = try snapshot.restore(c.alloc, io, payloads.items, 1024);
                            defer decoded.deinit(c.alloc);
                            var t = try decoded.toOwned();
                            errdefer t.deinit(c.alloc);
                            // Swap into the live slot (same address, so
                            // the client's stream stays bound).
                            cli_term_slot.deinit(c.alloc);
                            cli_term_slot.* = t;
                            done = true;
                            break;
                        }
                    } else |_| {}
                    _ = c.re.sweep(c.down.now_ns);
                }
            }
            if (!done) return error.Incomplete;
            // Rebase both diff sides to the snapshot state.
            srv.deinit();
            srv.* = try DiffServer.init(c.alloc, io, srv_term, state);
            shadow_feed.* = HeadlessFeed.init(c.alloc, &srv.shadow);
            cli_feed.* = HeadlessFeed.init(c.alloc, cli_term_slot);
            cli.feed = cli_feed.*;
            cli.current = state;
        }
    };

    var cx = Cx{
        .srv_tx = srv_tx,
        .cli_rx = cli_rx,
        .cli_tx = cli_tx,
        .srv_rx = srv_rx,
        .up = &up,
        .down = &down,
        .s_seal = &s_seal,
        .c_open = &c_open,
        .c_seal = &c_seal,
        .s_open = &s_open,
        .re = &re,
        .alloc = alloc,
    };

    var srv = try DiffServer.init(alloc, io, srv_h.term, 100);
    defer srv.deinit();
    var shadow_feed = HeadlessFeed.init(alloc, &srv.shadow);
    var cli_feed = HeadlessFeed.init(alloc, cli_h.term);
    var cli = DiffClient{ .current = 100, .feed = cli_feed };

    // Phase 1: big styled output (60 lines → scrollback churn).
    var step: usize = 0;
    while (step < 6) : (step += 1) {
        var line: [96]u8 = undefined;
        var k: usize = 0;
        while (k < 10) : (k += 1) {
            const text = try std.fmt.bufPrint(
                &line,
                "\x1b[1;3{d};4{d}mblk{d}-{d}\x1b[0m ",
                .{ step % 7 + 1, (step + k) % 7 + 1, step, k },
            );
            srv_h.feed(text);
        }
        srv_h.feed("\r\n");
        try cx.stepDiffs(&srv, &cli, srv_h.term);
    }
    try cx.settle(&srv, &shadow_feed, &cli);

    // Phase 2: resize 40x12 → 80x24 via snapshot resync.
    const snap_state: u32 = srv.next;
    try srv_h.term.resize(alloc, .{ .cols = 80, .rows = 24 });
    try cx.resync(io, srv_h.term, snap_state, &srv, &cli, cli_h.term, &shadow_feed, &cli_feed);
    try cx.settle(&srv, &shadow_feed, &cli);

    // Phase 3: more output on the new size.
    step = 0;
    while (step < 4) : (step += 1) {
        var line: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &line,
            "\x1b[38;5;{d}mwide-{d}\x1b[0m\r\n",
            .{ 100 + step * 10, step },
        );
        srv_h.feed(text);
        try cx.stepDiffs(&srv, &cli, srv_h.term);
    }
    try cx.settle(&srv, &shadow_feed, &cli);

    // Phase 4: simulated 30 s sleep gap (clocks advance, no traffic).
    up.advance(30 * std.time.ns_per_s);
    down.advance(30 * std.time.ns_per_s);
    up.pump();
    down.pump();

    // Phase 5: output after the gap (recovery proof).
    step = 0;
    while (step < 4) : (step += 1) {
        var line: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "postgap-{d}\r\n", .{step});
        srv_h.feed(text);
        try cx.stepDiffs(&srv, &cli, srv_h.term);
    }
    try cx.settle(&srv, &shadow_feed, &cli);

    // Phase 6: resize back 80x24 → 40x12 via snapshot resync.
    const snap_state2: u32 = srv.next;
    try srv_h.term.resize(alloc, .{ .cols = 40, .rows = 12 });
    try cx.resync(io, srv_h.term, snap_state2, &srv, &cli, cli_h.term, &shadow_feed, &cli_feed);
    try cx.settle(&srv, &shadow_feed, &cli);

    try testing.expectEqual(srv.next -% 1, cli.current);
    try testing.expectEqual(srv_h.term.cols, cli_h.term.cols);
    try testing.expectEqual(srv_h.term.rows, cli_h.term.rows);
    var y: u16 = 0;
    while (y < srv_h.term.rows) : (y += 1) {
        var x: u16 = 0;
        while (x < srv_h.term.cols) : (x += 1) {
            try testing.expect(cellsEqual(
                getCell(srv_h.term, x, y),
                getCell(cli_h.term, x, y),
            ));
        }
    }
}
