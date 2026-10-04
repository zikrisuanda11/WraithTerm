//! Predictive echo (P4.7, D10).
//!
//! Client-side speculation for high-latency links: printable input
//! shows immediately (marked underline/dim by the renderer — that
//! presentation is `[~]` headless), then is confirmed or rolled back
//! when the server state catches up.
//!
//! Rules (D10, all pure and unit-tested here):
//! - Mode `adaptive` enables prediction only when smoothed RTT
//!   exceeds 30 ms; `always`/`never` force it on/off.
//! - Predictable input: exactly one printable graphic character
//!   (no C0/C1, no DEL, no combining edge cases beyond a single
//!   codepoint), on the normal screen only (never alt-screen).
//! - Any prediction suspends on: Enter/control input, alt-screen
//!   entry, echo-off (password) mode. Suspension clears pending.
//! - Confirm: when the server state reaches the predicted epoch,
//!   pending predictions at or below it are confirmed (kept).
//! - Cancel: a server state whose screen disagrees with a pending
//!   prediction removes it (the renderer erases the marked echo).
//!
//! Epochs are client input sequence numbers; the server echoes the
//! highest applied input seq in its diffs (P4.5 `state_id` ordering
//! gives the same guarantee — the predictor keys off it).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// D10 mode for `wraith-predictive-echo`.
pub const Mode = enum {
    adaptive,
    always,
    never,

    /// Adaptive threshold: smoothed RTT above this enables prediction.
    pub const rtt_threshold_ns: u64 = 30 * std.time.ns_per_ms;
};

/// One pending prediction: the echoed text and the epoch (input seq)
/// it belongs to.
pub const Pending = struct {
    epoch: u64,
    text: [8]u8 = undefined,
    text_len: u8 = 0,
};

/// Predictor state machine (client side).
pub const Predictor = struct {
    mode: Mode = .adaptive,
    smoothed_rtt_ns: u64 = 0,
    /// Next epoch to assign.
    next_epoch: u64 = 1,
    /// Last server-confirmed epoch.
    confirmed_epoch: u64 = 0,
    /// Suspended (Enter/control, alt-screen, echo-off).
    held: bool = false,
    pending: std.ArrayList(Pending),

    pub fn init(alloc: Allocator) Predictor {
        _ = alloc;
        return .{
            .pending = .empty,
        };
    }

    pub fn deinit(self: *Predictor, alloc: Allocator) void {
        self.pending.deinit(alloc);
        self.* = undefined;
    }

    pub fn enabled(self: *const Predictor) bool {
        return switch (self.mode) {
            .always => true,
            .never => false,
            .adaptive => self.smoothed_rtt_ns > Mode.rtt_threshold_ns,
        };
    }

    /// Printable graphic input eligible for prediction: exactly one
    /// Unicode scalar, graphic (not control/space-sensitive: space
    /// IS predictable), not DEL.
    pub fn predictableInput(text: []const u8) ?u21 {
        if (text.len == 0 or text.len > 4) return null;
        const cp_len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
        if (cp_len != text.len) return null;
        const cp = std.unicode.utf8Decode(text[0..cp_len]) catch return null;
        if (cp < 0x20 or cp == 0x7F) return null;
        if (cp >= 0x80 and cp <= 0x9F) return null;
        return cp;
    }

    /// Offer locally-typed text. Returns the epoch when predicted
    /// (renderer shows it marked), else null (sent without echo).
    /// `alt_screen` / `echo_off` force suspension per D10.
    pub fn onLocalInput(
        self: *Predictor,
        alloc: Allocator,
        text: []const u8,
        alt_screen: bool,
        echo_off: bool,
    ) !?u64 {
        if (alt_screen or echo_off) {
            self.hold(alloc);
            return null;
        }
        // Enter/control suspends AND clears (D10).
        if (isControlInput(text)) {
            self.hold(alloc);
            return null;
        }
        if (!self.enabled() or self.held) return null;
        const cp = predictableInput(text) orelse return null;
        const epoch = self.next_epoch;
        self.next_epoch += 1;
        var p = Pending{ .epoch = epoch };
        const n = try std.unicode.utf8Encode(cp, &p.text);
        p.text_len = @intCast(n);
        try self.pending.append(alloc, p);
        return epoch;
    }

    /// Server state reached `epoch`: confirm everything at/below it.
    /// Returns the number confirmed.
    pub fn onServerState(self: *Predictor, alloc: Allocator, epoch: u64) usize {
        var confirmed: usize = 0;
        var kept: usize = 0;
        for (self.pending.items) |p| {
            if (p.epoch <= epoch) {
                confirmed += 1;
            } else {
                self.pending.items[kept] = p;
                kept += 1;
            }
        }
        self.pending.items.len = kept;
        _ = alloc;
        if (epoch > self.confirmed_epoch) self.confirmed_epoch = epoch;
        return confirmed;
    }

    /// Server screen disagrees with a prediction: cancel it (and any
    /// newer ones, which built on it). Returns cancellations.
    pub fn onMismatch(self: *Predictor, alloc: Allocator, epoch: u64) usize {
        var kept: usize = 0;
        for (self.pending.items) |p| {
            if (p.epoch < epoch) {
                self.pending.items[kept] = p;
                kept += 1;
            }
        }
        const n = self.pending.items.len - kept;
        self.pending.items.len = kept;
        _ = alloc;
        return n;
    }

    pub fn hold(self: *Predictor, alloc: Allocator) void {
        _ = alloc;
        self.held = true;
        self.pending.items.len = 0;
    }

    pub fn release(self: *Predictor) void {
        self.held = false;
    }

    /// Feed a smoothed RTT sample (EWMA α=1/8, integer math).
    pub fn sampleRtt(self: *Predictor, rtt_ns: u64) void {
        self.smoothed_rtt_ns = self.smoothed_rtt_ns * 7 / 8 + rtt_ns / 8;
    }

    fn isControlInput(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text.len == 1) {
            const c = text[0];
            // Enter (CR/LF), ESC, and C0 controls suspend.
            if (c == '\r' or c == '\n' or c == 0x1B or c < 0x20 or c == 0x7F) return true;
            return false;
        }
        // Multi-byte starting with ESC (arrow keys etc.) or C1.
        if (text[0] == 0x1B) return true;
        if (text.len >= 2 and text[0] == 0xC2 and text[1] >= 0x80 and text[1] <= 0x9F) return true;
        return false;
    }
};

test "predict: modes and rtt gate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Predictor.init(alloc);
    defer p.deinit(alloc);
    // Default adaptive, zero RTT: off.
    try testing.expect(!p.enabled());
    p.sampleRtt(240 * std.time.ns_per_ms);
    // EWMA: 0*7/8 + 240/8 = 30ms — needs STRICTLY above.
    try testing.expect(!p.enabled());
    p.sampleRtt(240 * std.time.ns_per_ms);
    // 30*7/8 + 30 = 56.25ms > 30ms: on.
    try testing.expect(p.enabled());
    p.mode = .never;
    try testing.expect(!p.enabled());
    p.mode = .always;
    try testing.expect(p.enabled());
}

test "predict: printable predicted, control suspends" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Predictor.init(alloc);
    defer p.deinit(alloc);
    p.mode = .always;
    const e1 = try p.onLocalInput(alloc, "a", false, false);
    try testing.expect(e1 != null);
    try testing.expectEqual(@as(usize, 1), p.pending.items.len);
    // Space is predictable.
    try testing.expect(try p.onLocalInput(alloc, " ", false, false) != null);
    // Multibyte printable works.
    try testing.expect(try p.onLocalInput(alloc, "é", false, false) != null);
    // Multi-codepoint is not predicted.
    try testing.expect(try p.onLocalInput(alloc, "ab", false, false) == null);
    // Enter suspends and clears.
    try testing.expect(try p.onLocalInput(alloc, "\r", false, false) == null);
    try testing.expect(p.held);
    try testing.expectEqual(@as(usize, 0), p.pending.items.len);
    // While suspended, nothing predicts.
    try testing.expect(try p.onLocalInput(alloc, "b", false, false) == null);
    p.release();
    try testing.expect(try p.onLocalInput(alloc, "b", false, false) != null);
    // Alt-screen and echo-off suspend.
    try testing.expect(try p.onLocalInput(alloc, "c", true, false) == null);
    p.release();
    try testing.expect(try p.onLocalInput(alloc, "c", false, true) == null);
}

test "predict: confirm and mismatch" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Predictor.init(alloc);
    defer p.deinit(alloc);
    p.mode = .always;
    _ = try p.onLocalInput(alloc, "a", false, false);
    _ = try p.onLocalInput(alloc, "b", false, false);
    _ = try p.onLocalInput(alloc, "c", false, false);
    // Server confirms through epoch 2: two confirmed, one left.
    try testing.expectEqual(@as(usize, 2), p.onServerState(alloc, 2));
    try testing.expectEqual(@as(usize, 1), p.pending.items.len);
    try testing.expectEqual(@as(u64, 3), p.pending.items[0].epoch);
    // Server disagrees at 3: cancel it.
    try testing.expectEqual(@as(usize, 1), p.onMismatch(alloc, 3));
    try testing.expectEqual(@as(usize, 0), p.pending.items.len);
    // Confirming nothing is a no-op.
    try testing.expectEqual(@as(usize, 0), p.onServerState(alloc, 3));
}
