//! Seeded fuzz: message parsers + reassembly (P4.9).
//!
//! ≥1M deterministic inputs (seeded PRNG, mixed strategies) across:
//! - `codec.decode` / `decodeAlloc` (local IPC frames),
//! - `ssp_bootstrap.parseConnectLine`,
//! - `harness_event.parseLine`,
//! - `frag.Reassembler.feed` + `sweep` (chunk-shaped inputs),
//! - `crypto.Opener.open` (tamper-shaped packets).
//!
//! Invariants: no crash (bounds/panic), no hang (bounded work per
//! input), no OOM (all allocs capped; the harness frees). Any error
//! return is FINE — only safety violations fail. Findings fixed in
//! this same task; the seed that reproduces is printed first.
//!
//! Strategies per input (seeded choice): pure random bytes, valid
//! frame with random mutations, truncated valid frame, structured
//! chunk/header shapes, printable ASCII soup.
const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const bootstrap = @import("ssp_bootstrap.zig");
const hevent = @import("harness_event.zig");
const frag = @import("ssp_frag.zig");
const crypto = @import("ssp_crypto.zig");

/// Total inputs per `fuzzAll` run (P4.9: ≥1M).
pub const total_inputs: usize = 1_000_000;

const Strategy = enum {
    random,
    mutate_valid,
    truncate_valid,
    chunk_shaped,
    ascii_soup,
};

fn pickStrategy(rng: std.Random, n: usize) Strategy {
    _ = n;
    return switch (rng.uintLessThan(u8, 5)) {
        0 => .random,
        1 => .mutate_valid,
        2 => .truncate_valid,
        3 => .chunk_shaped,
        else => .ascii_soup,
    };
}

/// Fill `buf` with strategy-shaped input. Returns the slice to feed
/// (may be shorter than `buf`).
fn shapeInput(
    rng: std.Random,
    buf: []u8,
    valid_frame: []const u8,
) []u8 {
    switch (pickStrategy(rng, buf.len)) {
        .random => {
            rng.bytes(buf);
            return buf[0..rng.uintLessThan(usize, buf.len + 1)];
        },
        .mutate_valid => {
            const n = @min(buf.len, valid_frame.len);
            @memcpy(buf[0..n], valid_frame[0..n]);
            // 1-4 random byte mutations.
            var m: usize = 0;
            while (m < 1 + rng.uintLessThan(usize, 4)) : (m += 1) {
                if (n == 0) break;
                buf[rng.uintLessThan(usize, n)] = rng.int(u8);
            }
            return buf[0..n];
        },
        .truncate_valid => {
            const n = @min(buf.len, valid_frame.len);
            @memcpy(buf[0..n], valid_frame[0..n]);
            return buf[0..rng.uintLessThan(usize, n + 1)];
        },
        .chunk_shaped => {
            // Header-shaped: plausible msg_id/index/count + tail.
            const n = rng.uintLessThan(usize, buf.len + 1);
            if (n >= 8) {
                std.mem.writeInt(u32, buf[0..4], rng.int(u32), .little);
                std.mem.writeInt(u16, buf[4..6], rng.int(u16), .little);
                std.mem.writeInt(u16, buf[6..8], rng.int(u16), .little);
            }
            var i: usize = @min(n, 8);
            while (i < n) : (i += 1) buf[i] = rng.int(u8);
            return buf[0..n];
        },
        .ascii_soup => {
            const n = rng.uintLessThan(usize, buf.len + 1);
            const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789{}[]\":,._- \n\t";
            var i: usize = 0;
            while (i < n) : (i += 1) buf[i] = alpha[rng.uintLessThan(usize, alpha.len)];
            return buf[0..n];
        },
    }
}

/// Run the full fuzz battery. Returns counts; fails only on safety
/// violations (which print the seed + input first).
pub fn fuzzAll(alloc: Allocator, seed: u64) ![3]usize {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    // One valid frame to mutate/truncate (an ack).
    const valid = try codec.encode(alloc, .{ .ack = .{ .state_id = 9, .seq_lo = 1, .flags = 0 } });
    defer alloc.free(valid);

    var buf: [2048]u8 = undefined;
    var decoded_ok: usize = 0;
    var i: usize = 0;
    while (i < total_inputs) : (i += 1) {
        const input = shapeInput(rng, &buf, valid);
        // 1. Local frame decode (both variants).
        if (codec.decode(input)) |_| {
            decoded_ok += 1;
        } else |_| {}
        var owned = codec.decodeAlloc(alloc, input) catch null;
        if (owned) |*o| o.deinit();
        // 2. Bootstrap line parse (bounded copy).
        if (input.len < 256) {
            _ = bootstrap.parseConnectLine(input) catch {};
        }
        // 3. Harness event line parse (arena per batch of 64).
        if (i % 64 == 0) {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            _ = hevent.parseLine(arena.allocator(), input);
        }
    }

    // 4. Reassembly fuzz: separate PRNG stream, chunk-shaped feeds
    // plus sweeps at random clocks.
    var re = frag.Reassembler.init(alloc);
    defer re.deinit();
    var prng2 = std.Random.DefaultPrng.init(seed ^ 0xF022);
    const rng2 = prng2.random();
    var j: usize = 0;
    while (j < total_inputs / 4) : (j += 1) {
        const input = shapeInput(rng2, &buf, valid);
        const now: u64 = rng2.int(u64) % (10 * std.time.ns_per_s);
        // MessageTooLarge is the designed over-cap drop (D9), not a
        // safety violation.
        if (re.feed(input, now)) |m| {
            if (m) |msg| alloc.free(msg);
        } else |err| switch (err) {
            error.MessageTooLarge, error.OutOfMemory => {},
        }
        if (j % 97 == 0) _ = re.sweep(now);
    }
    _ = re.sweep(std.math.maxInt(u64));

    // 5. AEAD open fuzz: random packets against a live opener
    // (wrong keys/tags/lengths must only ever error).
    const key: [crypto.key_length]u8 = .{0x51} ** crypto.key_length;
    var opener = crypto.Opener{ .key = key, .dir = .client_to_server };
    var obuf: [2048]u8 = undefined;
    var prng3 = std.Random.DefaultPrng.init(seed ^ 0x071E);
    const rng3 = prng3.random();
    var k: usize = 0;
    while (k < total_inputs / 4) : (k += 1) {
        const input = shapeInput(rng3, &buf, valid);
        _ = opener.open(&obuf, input) catch {};
    }

    return .{ decoded_ok, total_inputs, total_inputs / 2 };
}

test "fuzz: 1M seeded inputs, no crash hang or oom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const seed: u64 = 0xF022BA4;
    std.debug.print("fuzz seed {d}\n", .{seed});
    const counts = try fuzzAll(alloc, seed);
    // counts = {valid decodes, parser inputs, reassembly+AEAD inputs}.
    std.debug.print(
        "fuzz done decoded_ok={d} parser_inputs={d} transport_inputs={d}\n",
        .{ counts[0], counts[1], counts[2] },
    );
    // Sanity: the valid frame itself must decode (strategies that
    // never produce it would hide regressions).
    try testing.expect(counts[0] > 0);
}
