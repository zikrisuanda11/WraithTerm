//! Roaming + reconnect (P4.6, AC2.4, PROTOCOL §8).
//!
//! The AEAD layer (P4.1) authenticates content independent of
//! source address (Mosh model): roaming falls out naturally —
//! `PeerTracker` updates the peer address ONLY from authenticated
//! packets with a higher seq, so replays/forgeries from another
//! address can never hijack the session. Reconnect after sleep is
//! just the client sending its highest sealed seq from the new
//! address; the server continues diffs from the acked state (P4.5).
//!
//! Pure over caller-supplied addresses (`[16]u8` blobs: IPv4-mapped
//! or IPv6 + port bytes; the tracker never interprets them).
const std = @import("std");
const crypto = @import("ssp_crypto.zig");

/// Opaque peer address (16 bytes: v6 or v4-mapped + port).
pub const Addr = [16]u8;

/// Tracks the currently accepted peer address for one direction.
/// `noteAuthenticated` moves it forward only.
pub const PeerTracker = struct {
    current: ?Addr = null,
    top_seq: u64 = 0,
    have_seq: bool = false,

    pub const Verdict = enum {
        /// First authenticated packet: adopt address + seq.
        adopt,
        /// Same address, newer seq: refresh.
        refresh,
        /// New address, newer seq: roam.
        roam,
        /// Same address, old/dup seq: ignore (replay layer decides).
        stale,
        /// New address but NOT newer seq: possible hijack, ignore.
        suspect,
    };

    /// Classify an authenticated packet's (addr, seq). Call ONLY
    /// after AEAD auth passed — address is untrusted input.
    pub fn noteAuthenticated(self: *PeerTracker, addr: Addr, seq: u64) Verdict {
        if (!self.have_seq) {
            self.current = addr;
            self.top_seq = seq;
            self.have_seq = true;
            return .adopt;
        }
        const same = std.mem.eql(u8, &self.current.?, &addr);
        if (seq > self.top_seq) {
            self.top_seq = seq;
            if (!same) self.current = addr;
            return if (same) .refresh else .roam;
        }
        return if (same) .stale else .suspect;
    }

    pub fn peer(self: *const PeerTracker) ?Addr {
        return self.current;
    }
};

/// Full roaming handshake helper: seal a packet and record its seq
/// for the tracker (test/server glue).
pub fn sealTracked(
    sealer: *crypto.Sealer,
    out: []u8,
    plain: []const u8,
    flags: u8,
) struct { pkt: []u8, seq: u64 } {
    const seq = sealer.next_seq;
    const pkt = sealer.seal(out, plain, flags) catch unreachable;
    return .{ .pkt = pkt, .seq = seq };
}

test "roam: adopt refresh roam stale suspect" {
    const testing = std.testing;
    var t = PeerTracker{};
    const a: Addr = .{1} ** 16;
    const b: Addr = .{2} ** 16;
    try testing.expectEqual(PeerTracker.Verdict.adopt, t.noteAuthenticated(a, 10));
    try testing.expectEqual(a, t.peer().?);
    try testing.expectEqual(PeerTracker.Verdict.refresh, t.noteAuthenticated(a, 11));
    try testing.expectEqual(PeerTracker.Verdict.stale, t.noteAuthenticated(a, 11));
    try testing.expectEqual(PeerTracker.Verdict.stale, t.noteAuthenticated(a, 5));
    // New address with newer seq: roam.
    try testing.expectEqual(PeerTracker.Verdict.roam, t.noteAuthenticated(b, 12));
    try testing.expectEqual(b, t.peer().?);
    // Old seq from another address: suspect, peer unchanged.
    try testing.expectEqual(PeerTracker.Verdict.suspect, t.noteAuthenticated(a, 3));
    try testing.expectEqual(b, t.peer().?);
    // Equal seq from another address: suspect (not newer).
    try testing.expectEqual(PeerTracker.Verdict.suspect, t.noteAuthenticated(a, 12));
    try testing.expectEqual(b, t.peer().?);
}

test "roam: session survives address change, rejects hijack" {
    const testing = std.testing;
    const alloc = testing.allocator;
    _ = alloc;
    const key: [crypto.key_length]u8 = .{0x46} ** crypto.key_length;
    var sealer = crypto.Sealer{ .key = key, .dir = .client_to_server };
    var opener = crypto.Opener{ .key = key, .dir = .client_to_server };
    var tracker = PeerTracker{};
    const addr_a: Addr = .{0x0A} ** 16;
    const addr_b: Addr = .{0x0B} ** 16;
    const addr_evil: Addr = .{0xE0} ** 16;
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    // Packets 0..2 from address A: adopted then refreshed.
    // Capture packet 0's bytes for the later replay attempt.
    var captured: [128]u8 = undefined;
    var captured_len: usize = 0;
    var seq: u64 = 0;
    while (seq < 3) : (seq += 1) {
        const s = sealTracked(&sealer, &pkt, "legit", 0);
        if (seq == 0) {
            captured_len = s.pkt.len;
            @memcpy(captured[0..captured_len], s.pkt);
        }
        const plain = try opener.open(&out, s.pkt);
        _ = plain;
        try testing.expect(
            tracker.noteAuthenticated(addr_a, s.seq) != .suspect,
        );
    }
    // Attacker replays captured packet seq 0 from another address:
    // the opener rejects it as a replay, and even on its own the
    // tracker would classify it suspect (not newer than top=2).
    try testing.expectError(error.Replayed, opener.open(&out, captured[0..captured_len]));
    try testing.expectEqual(PeerTracker.Verdict.suspect, tracker.noteAuthenticated(addr_evil, 0));
    try testing.expectEqual(addr_a, tracker.peer().?);
    // Client roams to B and sends seq 3: accepted, peer moves.
    {
        const s = sealTracked(&sealer, &pkt, "roamed", 0);
        const plain = try opener.open(&out, s.pkt);
        _ = plain;
        try testing.expectEqual(PeerTracker.Verdict.roam, tracker.noteAuthenticated(addr_b, s.seq));
        try testing.expectEqual(addr_b, tracker.peer().?);
    }
    // Attacker forges with a WRONG key: auth fails before tracking.
    // (Fresh opener: seq unseen, so only the key can reject it.)
    {
        var evil_sealer = crypto.Sealer{ .key = .{0x99} ** crypto.key_length, .dir = .client_to_server };
        const s = sealTracked(&evil_sealer, &pkt, "forged", 0);
        var fresh = crypto.Opener{ .key = key, .dir = .client_to_server };
        try testing.expectError(error.AuthFailed, fresh.open(&out, s.pkt));
    }
}
