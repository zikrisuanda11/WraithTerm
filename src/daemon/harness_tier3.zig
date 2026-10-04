//! Tier 3 ANSI fallback classifier (P2.10, D6).
//!
//! Best-effort harness-state guesses from raw terminal output for
//! harnesses WITHOUT an event API. Pure functions over text lines
//! (and OSC title text); confidence is ALWAYS low — Tier 3 never
//! outranks Tier 1 or Tier 2, and `unknown` is a normal result.
//!
//! Signal set (all observed in the wild, see `HARNESS_OMP.md` and
//! the orca title-marker convention `π ! session - cwd`):
//! - approval prompts: `(y/n)`, `[y/n]`, `allow?`, `approve`, `?`
//!   at end of line, `!` title marker → `awaiting_approval`
//! - tool-activity verbs/glyphs (`running`, `executing`, `calling`,
//!   `editing`, `writing`, `reading`, `⏺`, `✻`, `●` …) → `executing_tool`
//! - braille spinner frames (U+2800–U+28FF) → `thinking`
//! - anything else → `unknown`
const std = @import("std");
const hevent = @import("harness_event.zig");

/// Tier 3 is always best-effort.
pub const Confidence = enum {
    low,
};

pub const Guess = struct {
    state: hevent.State,
    confidence: Confidence = .low,
};

/// Classify one terminal output line (already stripped of escape
/// sequences by the caller; matching is case-insensitive ASCII).
pub fn classifyLine(line: []const u8) Guess {
    if (looksLikeApproval(line)) return .{ .state = .awaiting_approval };
    if (looksLikeToolActivity(line)) return .{ .state = .executing_tool };
    if (hasBraille(line)) return .{ .state = .thinking };
    return .{ .state = .unknown };
}

/// Classify OSC 0/2 title text. The orca convention marks
/// needs-input titles with `!`
pub fn classifyTitle(title: []const u8) Guess {
    if (std.mem.indexOfScalar(u8, title, '!') != null) {
        return .{ .state = .awaiting_approval };
    }
    if (hasBraille(title)) return .{ .state = .thinking };
    return .{ .state = .unknown };
}

fn lowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (lowerByte(haystack[i + j]) != lowerByte(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn looksLikeApproval(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (containsFold(trimmed, "(y/n)") or containsFold(trimmed, "[y/n]")) return true;
    if (containsFold(trimmed, "allow?") or containsFold(trimmed, "approve")) return true;
    if (containsFold(trimmed, "awaiting approval") or
        containsFold(trimmed, "waiting for user input")) return true;
    // A bare trailing `?` on a short prompt line (not a long
    // sentence): `Run tests?`, `Proceed?`.
    if (trimmed[trimmed.len - 1] == '?' and trimmed.len < 80) {
        // Exclude sentences (contain `. ` before the question).
        if (std.mem.indexOf(u8, trimmed, ". ") == null) return true;
    }
    return false;
}

fn looksLikeToolActivity(line: []const u8) bool {
    const verbs = [_][]const u8{
        "running",
        "executing",
        "calling",
        "editing",
        "writing",
        "reading",
        "searching",
        "applying",
        "tool:",
    };
    for (verbs) |v| {
        if (containsFold(line, v)) return true;
    }
    // Agent status glyphs (U+23FA, U+273B, U+25CF).
    const glyphs = [_][]const u8{ "⏺", "✻", "●" };
    for (glyphs) |g| {
        if (std.mem.indexOf(u8, line, g) != null) return true;
    }
    return false;
}

/// Any braille pattern (U+2800–U+28FF: E2 A0 80–E2 A8 BF in UTF-8).
fn hasBraille(s: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == 0xE2 and s[i + 1] >= 0xA0 and s[i + 1] <= 0xA8 and
            s[i + 2] >= 0x80 and s[i + 2] <= 0xBF)
        {
            return true;
        }
    }
    return false;
}

test "tier3: approval prompts" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "Allow running `cargo test`? (y/n)",
        "approve edit to src/main.zig [y/n]",
        "Proceed with 3 edits?",
        "Run the migration?",
        "awaiting approval",
        "✔ Done — waiting for user input",
    };
    for (cases) |c| {
        const g = classifyLine(c);
        try testing.expectEqual(hevent.State.awaiting_approval, g.state);
        try testing.expectEqual(Confidence.low, g.confidence);
    }
    // Long sentences ending in `?` are NOT approvals.
    try testing.expectEqual(
        hevent.State.unknown,
        classifyLine("Did you know the build takes a while. Really? that's a long story about caching.").state,
    );
}

test "tier3: tool activity" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "⏺ Running `zig build`…",
        "✻ Executing 12 tool calls…",
        "● Editing src/daemon/server.zig",
        "Calling read on docs/wraith/PROGRESS.md",
        "tool: write file=out.txt",
        "SEARCHING the codebase for harness events",
    };
    for (cases) |c| {
        try testing.expectEqual(hevent.State.executing_tool, classifyLine(c).state);
    }
}

test "tier3: braille spinner means thinking" {
    const testing = std.testing;
    try testing.expectEqual(hevent.State.thinking, classifyLine("⠋ Working…").state);
    try testing.expectEqual(hevent.State.thinking, classifyTitle("⠋ omp - myproject").state);
    try testing.expectEqual(hevent.State.awaiting_approval, classifyTitle("π ! sess - proj").state);
    try testing.expectEqual(hevent.State.unknown, classifyTitle("omp - myproject").state);
}

test "tier3: ordinary output is unknown" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "",
        "   ",
        "hello world",
        "test passed; 40 skipped; 0 failed.",
        "Compiling src/daemon/codec.zig",
        "error: expected type 'bool', found 'u8'",
    };
    for (cases) |c| {
        const g = classifyLine(c);
        try testing.expectEqual(hevent.State.unknown, g.state);
        try testing.expectEqual(Confidence.low, g.confidence);
    }
    try testing.expectEqual(hevent.State.unknown, classifyTitle("bash — ghostty").state);
}
