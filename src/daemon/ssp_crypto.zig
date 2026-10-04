//! SSP crypto: ChaCha20-Poly1305 sessions (P4.1, D3).
//!
//! - Key: 32 random bytes per session from bootstrap (no rotation,
//!   no Noise in v1).
//! - Nonce (12 B) = `[u32 dir][u64 seq LE]`; `dir` is 0 client→server,
//!   1 server→client. One counter per direction, strictly increasing:
//!   a nonce is never reused under one key.
//! - Header (`[u64 seq LE][u8 flags]`) is the AAD. Auth failures are
//!   silent drops (no reply) — callers map to `error.AuthFailed`.
//! - Replay window: 1024 packets per direction (sliding bitmap);
//!   old or repeated seqs are rejected.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

/// Session key length (D3).
pub const key_length: usize = 32;
/// Nonce length: `[u32 dir][u64 seq LE]` (D3).
pub const nonce_length: usize = 12;
/// Auth tag length.
pub const tag_length: usize = 16;
/// Replay window bits per direction (D3).
pub const window_bits = 1024;
/// Header length: `[u64 seq LE][u8 flags]` (also the AAD).
pub const header_len = 9;

/// Direction tag in the nonce (D3).
pub const Direction = enum(u32) {
    client_to_server = 0,
    server_to_client = 1,
};

pub const SealError = Allocator.Error || error{CounterExhausted};

/// One sending direction: owns the sequence counter. Never shares a
/// counter across directions (the nonce `dir` word differs too, so
/// even equal counters cannot collide).
pub const Sealer = struct {
    key: [key_length]u8,
    dir: Direction,
    next_seq: u64 = 0,

    /// Seal `plain` into `out` (`cipher ++ tag`). `out` must hold
    /// `plain.len + tag_length`. Header (seq+flags) is prepended by
    /// the caller? No — this writes `[header][cipher][tag]` whole:
    /// `out` must hold `header_len + plain.len + tag_length`.
    /// Returns the full sealed packet slice.
    pub fn seal(
        self: *Sealer,
        out: []u8,
        plain: []const u8,
        flags: u8,
    ) SealError![]u8 {
        if (self.next_seq == std.math.maxInt(u64)) return error.CounterExhausted;
        const seq = self.next_seq;
        self.next_seq += 1;
        std.debug.assert(out.len >= header_len + plain.len + tag_length);
        const pkt = out[0 .. header_len + plain.len + tag_length];
        std.mem.writeInt(u64, pkt[0..8], seq, .little);
        pkt[8] = flags;
        const cipher = pkt[header_len .. header_len + plain.len];
        const tag: *[tag_length]u8 = pkt[header_len + plain.len ..][0..tag_length];
        Aead.encrypt(cipher, tag, plain, pkt[0..header_len], nonce(self.dir, seq), self.key);
        return pkt;
    }

    pub fn nonce(dir: Direction, seq: u64) [nonce_length]u8 {
        var n: [nonce_length]u8 = undefined;
        std.mem.writeInt(u32, n[0..4], @intFromEnum(dir), .little);
        std.mem.writeInt(u64, n[4..12], seq, .little);
        return n;
    }
};

/// One receiving direction: sliding replay window + auth. Farthest
/// accepted seq is `top`; bit `i` marks `top - i` seen.
pub const Opener = struct {
    key: [key_length]u8,
    dir: Direction,
    top: u64 = 0,
    seen0: u64 = 0,
    bitmap: [window_bits / 64]u64 = .{0} ** (window_bits / 64),
    have_top: bool = false,

    pub const OpenError = error{ TooShort, AuthFailed, Replayed, TooOld };

    /// Open `pkt` (`[header][cipher][tag]`) into `out` (must hold
    /// `pkt.len - header_len - tag_length`). Returns plaintext slice.
    /// Auth failures, replays, and outside-window seqs are all
    /// rejections (the transport drops them silently per D3).
    pub fn open(
        self: *Opener,
        out: []u8,
        pkt: []const u8,
    ) OpenError![]u8 {
        if (pkt.len < header_len + tag_length) return error.TooShort;
        const seq = std.mem.readInt(u64, pkt[0..8], .little);
        if (!self.fresh(seq)) return if (self.seen(seq)) error.Replayed else error.TooOld;
        const cipher = pkt[header_len .. pkt.len - tag_length];
        const tag: [tag_length]u8 = pkt[pkt.len - tag_length ..][0..tag_length].*;
        std.debug.assert(out.len >= cipher.len);
        const plain = out[0..cipher.len];
        Aead.decrypt(plain, cipher, tag, pkt[0..header_len], Sealer.nonce(self.dir, seq), self.key) catch
            return error.AuthFailed;
        self.mark(seq);
        return plain;
    }

    fn seen(self: *const Opener, seq: u64) bool {
        if (!self.have_top or seq > self.top) return false;
        const d = self.top - seq;
        if (d >= window_bits) return false;
        return self.bitmap[d / 64] & (@as(u64, 1) << @intCast(d % 64)) != 0;
    }

    fn fresh(self: *const Opener, seq: u64) bool {
        if (!self.have_top) return true;
        if (seq > self.top) return true;
        const d = self.top - seq;
        if (d >= window_bits) return false;
        return self.bitmap[d / 64] & (@as(u64, 1) << @intCast(d % 64)) == 0;
    }

    fn mark(self: *Opener, seq: u64) void {
        if (!self.have_top or seq > self.top) {
            const shift = if (!self.have_top) 0 else seq - self.top;
            if (shift >= window_bits) {
                self.bitmap = .{0} ** (window_bits / 64);
            } else if (shift > 0) {
                // Aging: entries move to HIGHER bit indices as `top`
                // advances (entry at distance d moves to d+shift), so
                // shift the bitmap left across words; overflow off the
                // top word ages out of the window.
                const word_shift = shift / 64;
                const bit_shift: u6 = @intCast(shift % 64);
                var i: usize = self.bitmap.len;
                while (i > 0) {
                    i -= 1;
                    var v: u64 = 0;
                    if (i >= word_shift) {
                        v = self.bitmap[i - word_shift] << bit_shift;
                        if (bit_shift != 0 and i > word_shift) {
                            const fwd: u6 = @intCast(64 - @as(u7, bit_shift));
                            v |= self.bitmap[i - word_shift - 1] >> fwd;
                        }
                    }
                    self.bitmap[i] = v;
                }
            }
            self.top = seq;
            self.have_top = true;
        }
        const d = self.top - seq;
        self.bitmap[d / 64] |= @as(u64, 1) << @intCast(d % 64);
    }
};

test "crypto: round trip both directions" {
    const testing = std.testing;
    const key: [key_length]u8 = .{0x11} ** key_length;
    var cs = Sealer{ .key = key, .dir = .client_to_server };
    var sc = Sealer{ .key = key, .dir = .server_to_client };
    var cs_o = Opener{ .key = key, .dir = .client_to_server };
    var sc_o = Opener{ .key = key, .dir = .server_to_client };
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const sealed = try cs.seal(&pkt, "hello remote", 0x03);
    try testing.expectEqual(@as(usize, header_len + 12 + tag_length), sealed.len);
    const plain = try cs_o.open(&out, sealed);
    try testing.expectEqualStrings("hello remote", plain);
    // Flags ride the AAD: bit flips are caught.
    try testing.expectEqual(@as(u8, 0x03), sealed[8]);
    const back = try sc.seal(&pkt, "ack", 0);
    const bplain = try sc_o.open(&out, back);
    try testing.expectEqualStrings("ack", bplain);
}

test "crypto: tamper rejected, directions isolated" {
    const testing = std.testing;
    const key: [key_length]u8 = .{0x11} ** key_length;
    var cs = Sealer{ .key = key, .dir = .client_to_server };
    var cs_o = Opener{ .key = key, .dir = .client_to_server };
    var sc_o = Opener{ .key = key, .dir = .server_to_client };
    var pkt: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const sealed = try cs.seal(&pkt, "secret", 0);
    var bad = [_]u8{0} ** 128;
    @memcpy(bad[0..sealed.len], sealed);
    // Flip a ciphertext byte.
    bad[header_len] ^= 0x01;
    try testing.expectError(error.AuthFailed, cs_o.open(&out, bad[0..sealed.len]));
    // Flip a header (AAD) byte.
    bad = [_]u8{0} ** 128;
    @memcpy(bad[0..sealed.len], sealed);
    bad[8] ^= 0x01;
    try testing.expectError(error.AuthFailed, cs_o.open(&out, bad[0..sealed.len]));
    // Wrong direction cannot open (nonce dir differs).
    try testing.expectError(error.AuthFailed, sc_o.open(&out, sealed));
    // Too short.
    try testing.expectError(error.TooShort, cs_o.open(&out, sealed[0..4]));
}

test "crypto: replay and window" {
    const testing = std.testing;
    const key: [key_length]u8 = .{0x11} ** key_length;
    var cs = Sealer{ .key = key, .dir = .client_to_server };
    var o = Opener{ .key = key, .dir = .client_to_server };
    var pkt: [4096]u8 = undefined;
    var out: [4096]u8 = undefined;
    // Seal 5 packets.
    var sealed: [5][]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var tmp: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&tmp, "msg{d}", .{i});
        sealed[i] = try cs.seal(pkt[i * 256 ..][0..256], msg, 0);
    }
    // In-order open works.
    for (sealed) |s| _ = try o.open(&out, s);
    // Exact replay rejected.
    try testing.expectError(error.Replayed, o.open(&out, sealed[2]));
    try testing.expectError(error.Replayed, o.open(&out, sealed[4]));
    // Jump far ahead, then the old ones are outside the window.
    var j: usize = 0;
    while (j < window_bits + 10) : (j += 1) {
        const s = try cs.seal(pkt[1024..][0..128], "x", 0);
        _ = try o.open(&out, s);
    }
    try testing.expectError(error.TooOld, o.open(&out, sealed[0]));
}

test "crypto: nonces never repeat per direction" {
    const testing = std.testing;
    const key: [key_length]u8 = .{0x11} ** key_length;
    const cs0 = Sealer{ .key = key, .dir = .client_to_server };
    var cs = cs0;
    var seen: [16][nonce_length]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        seen[i] = Sealer.nonce(cs.dir, cs.next_seq);
        var pkt: [32]u8 = undefined;
        _ = try cs.seal(&pkt, "n", 0);
    }
    for (seen, 0..) |a, x| {
        for (seen[x + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, &a, &b));
    }
    // Direction words differ for equal counters.
    try testing.expect(!std.mem.eql(
        u8,
        &Sealer.nonce(.client_to_server, 7),
        &Sealer.nonce(.server_to_client, 7),
    ));
}
