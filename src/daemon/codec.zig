//! WraithTerm message codec (P1.2).
//!
//! Binary encode/decode for the D9 message model shared by local IPC and
//! SSP (`docs/wraith/PROTOCOL.md`). Little-endian, no external
//! serialization library. Follows the repo's snapshot-codec style:
//! explicit integer widths, unions over a `Type` tag, per-module error
//! sets. Unlike the snapshot codec this one works on whole frames in
//! memory (messages are <= 1 MiB) and decodes zero-copy: variable-length
//! fields alias the input buffer, so the buffer must outlive the decoded
//! message.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Protocol version negotiated in every frame (D9).
pub const protocol_version: u8 = 1;

/// Maximum `length` field value: message bodies larger than this are
/// rejected before any further allocation (D9).
pub const max_message_len: u32 = 1024 * 1024;

/// Message type byte (`PROTOCOL.md` §3).
pub const Type = enum(u8) {
    hello = 0x01,
    snapshot = 0x02,
    diff = 0x03,
    input = 0x04,
    resize = 0x05,
    control = 0x06,
    detached = 0x07,
    telemetry = 0x08,
    image_chunk = 0x09,
    ack = 0x0A,
    @"error" = 0x7F,
};

/// Wire error codes (`PROTOCOL.md` §4.12).
pub const ErrorCode = enum(u8) {
    bad_version = 0x01,
    unknown_message = 0x02,
    malformed = 0x03,
    too_large = 0x04,
    unauthorized = 0x05,
    no_such_session = 0x06,
    busy = 0x07,
    replay = 0x08,
    timeout = 0x09,
};

/// Local decode failures. These never appear on the wire; the peer gets
/// an `Error` message with the corresponding `ErrorCode` instead.
pub const DecodeError = error{
    /// Fewer bytes than the frame header or the claimed `length`.
    Truncated,
    /// Trailing bytes after exactly one frame.
    Trailing,
    /// `length` below the 2-byte minimum or above `max_message_len`.
    BadLength,
    /// `protocol_version` field is not 1.
    BadVersion,
    /// `msg_type` byte is not a known `Type`.
    UnknownMessage,
    /// Payload too short for its fixed fields, or an enum-valued field
    /// (role, kind, command, reason, mime tag) holds an unknown value.
    Malformed,
};

pub const Role = enum(u8) {
    client = 0,
    daemon = 1,
};

pub const Hello = struct {
    version_min: u16,
    version_max: u16,
    capabilities: u16,
    role: Role,
    /// Session ID (8 hex chars) or empty for the daemon side.
    id: []const u8,
};

pub const Snapshot = struct {
    state_id: u32,
    cols: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    flags: u8,
    cursor_style: u8,
    chunk_index: u16,
    chunk_count: u16,
    /// Opaque grid/scrollback bytes (Ghostty snapshot format).
    payload: []const u8,
};

pub const DiffSpan = struct {
    start_x: u16,
    start_y: u16,
    cell_count: u16,
    glyphs: []const u8,
    style_data: []const u8,
};

pub const Diff = struct {
    base_state_id: u32,
    state_id: u32,
    spans: []const DiffSpan,
};

pub const InputKind = enum(u8) {
    key = 0,
    text = 1,
    mouse = 2,
    paste = 3,
    focus = 4,
};

pub const Input = struct {
    kind: InputKind,
    /// PTY-ready bytes, already transcoded by the client.
    data: []const u8,
};

pub const Resize = struct {
    cols: u16,
    rows: u16,
    cell_width_px: u16,
    cell_height_px: u16,
    flags: u8,
};

pub const ControlCommand = enum(u8) {
    request_snapshot = 0x01,
    take_over = 0x02,
    detach = 0x03,
    kill_session = 0x04,
    list_sessions = 0x05,
    exit_when_empty = 0x06,
};

pub const Control = struct {
    command: ControlCommand,
    /// Only meaningful for `exit_when_empty` (`u8 on`).
    on: u8 = 0,
    has_on: bool = false,
};

pub const DetachReason = enum(u8) {
    taken_over = 0,
    server_shutdown = 1,
    idle_timeout = 2,
};

pub const Detached = struct {
    reason: DetachReason,
};

pub const Telemetry = struct {
    /// One JSON-lines harness event object (D6), <= 4 KiB.
    event: []const u8,
    origin_session_id: u32,
};

pub const MimeTag = enum(u8) {
    png = 0,
    jpeg = 1,
};

pub const ImageChunk = struct {
    image_id: u16,
    chunk_index: u16,
    chunk_count: u16,
    mime: MimeTag,
    data: []const u8,
};

pub const Ack = struct {
    state_id: u32,
    seq_lo: u16,
    flags: u16,
};

pub const ErrorMsg = struct {
    code: ErrorCode,
    /// Human-readable UTF-8. MUST NOT carry screen/input/key material.
    message: []const u8,
};

pub const Message = union(Type) {
    hello: Hello,
    snapshot: Snapshot,
    diff: Diff,
    input: Input,
    resize: Resize,
    control: Control,
    detached: Detached,
    telemetry: Telemetry,
    image_chunk: ImageChunk,
    ack: Ack,
    @"error": ErrorMsg,
};

const frame_header_len = 4 + 1 + 1;

fn payloadLen(msg: Message) usize {
    return switch (msg) {
        .hello => |m| 2 + 2 + 2 + 1 + 2 + m.id.len,
        .snapshot => |m| 4 + 2 + 2 + 2 + 2 + 1 + 1 + 2 + 2 + 4 + m.payload.len,
        .diff => |m| blk: {
            var n: usize = 4 + 4 + 2;
            for (m.spans) |s| {
                n += 2 + 2 + 2 + 4 + s.glyphs.len + 4 + s.style_data.len;
            }
            break :blk n;
        },
        .input => |m| 1 + 4 + m.data.len,
        .resize => 2 + 2 + 2 + 2 + 1,
        .control => |m| 1 + @as(usize, if (m.has_on) 1 else 0),
        .detached => 1,
        .telemetry => |m| 2 + m.event.len + 4,
        .image_chunk => |m| 2 + 2 + 2 + 1 + 4 + m.data.len,
        .ack => 4 + 2 + 2,
        .@"error" => |m| 1 + 2 + m.message.len,
    };
}

fn writeU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

fn writeU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

/// Encode one message as a single complete frame:
/// `[u32 length][u8 version][u8 type][payload]`. The caller owns the
/// returned slice.
pub fn encode(alloc: Allocator, msg: Message) Allocator.Error![]u8 {
    const payload_len = payloadLen(msg);
    const body_len = 1 + 1 + payload_len;
    assert(body_len >= 2);
    const out = try alloc.alloc(u8, frame_header_len + payload_len);
    // length = version + type + payload bytes (excludes itself).
    writeU32(out, 0, @intCast(body_len));
    out[4] = protocol_version;
    out[5] = @intFromEnum(msg);
    var off: usize = 6;
    switch (msg) {
        .hello => |m| {
            writeU16(out, off, m.version_min);
            off += 2;
            writeU16(out, off, m.version_max);
            off += 2;
            writeU16(out, off, m.capabilities);
            off += 2;
            out[off] = @intFromEnum(m.role);
            off += 1;
            writeU16(out, off, @intCast(m.id.len));
            off += 2;
            @memcpy(out[off..][0..m.id.len], m.id);
            off += m.id.len;
        },
        .snapshot => |m| {
            writeU32(out, off, m.state_id);
            off += 4;
            writeU16(out, off, m.cols);
            off += 2;
            writeU16(out, off, m.rows);
            off += 2;
            writeU16(out, off, m.cursor_x);
            off += 2;
            writeU16(out, off, m.cursor_y);
            off += 2;
            out[off] = m.flags;
            off += 1;
            out[off] = m.cursor_style;
            off += 1;
            writeU16(out, off, m.chunk_index);
            off += 2;
            writeU16(out, off, m.chunk_count);
            off += 2;
            writeU32(out, off, @intCast(m.payload.len));
            off += 4;
            @memcpy(out[off..][0..m.payload.len], m.payload);
            off += m.payload.len;
        },
        .diff => |m| {
            writeU32(out, off, m.base_state_id);
            off += 4;
            writeU32(out, off, m.state_id);
            off += 4;
            writeU16(out, off, @intCast(m.spans.len));
            off += 2;
            for (m.spans) |s| {
                writeU16(out, off, s.start_x);
                off += 2;
                writeU16(out, off, s.start_y);
                off += 2;
                writeU16(out, off, s.cell_count);
                off += 2;
                // NOTE: `glyphs_len` is a P1.2 correction to PROTOCOL.md
                // §4.3, which listed bare `glyphs[...]` with no length:
                // without it a span carrying both glyphs and style data
                // cannot be delimited.
                writeU32(out, off, @intCast(s.glyphs.len));
                off += 4;
                @memcpy(out[off..][0..s.glyphs.len], s.glyphs);
                off += s.glyphs.len;
                writeU32(out, off, @intCast(s.style_data.len));
                off += 4;
                @memcpy(out[off..][0..s.style_data.len], s.style_data);
                off += s.style_data.len;
            }
        },
        .input => |m| {
            out[off] = @intFromEnum(m.kind);
            off += 1;
            writeU32(out, off, @intCast(m.data.len));
            off += 4;
            @memcpy(out[off..][0..m.data.len], m.data);
            off += m.data.len;
        },
        .resize => |m| {
            writeU16(out, off, m.cols);
            off += 2;
            writeU16(out, off, m.rows);
            off += 2;
            writeU16(out, off, m.cell_width_px);
            off += 2;
            writeU16(out, off, m.cell_height_px);
            off += 2;
            out[off] = m.flags;
            off += 1;
        },
        .control => |m| {
            out[off] = @intFromEnum(m.command);
            off += 1;
            if (m.has_on) {
                out[off] = m.on;
                off += 1;
            }
        },
        .detached => |m| {
            out[off] = @intFromEnum(m.reason);
            off += 1;
        },
        .telemetry => |m| {
            writeU16(out, off, @intCast(m.event.len));
            off += 2;
            @memcpy(out[off..][0..m.event.len], m.event);
            off += m.event.len;
            writeU32(out, off, m.origin_session_id);
            off += 4;
        },
        .image_chunk => |m| {
            writeU16(out, off, m.image_id);
            off += 2;
            writeU16(out, off, m.chunk_index);
            off += 2;
            writeU16(out, off, m.chunk_count);
            off += 2;
            out[off] = @intFromEnum(m.mime);
            off += 1;
            writeU32(out, off, @intCast(m.data.len));
            off += 4;
            @memcpy(out[off..][0..m.data.len], m.data);
            off += m.data.len;
        },
        .ack => |m| {
            writeU32(out, off, m.state_id);
            off += 4;
            writeU16(out, off, m.seq_lo);
            off += 2;
            writeU16(out, off, m.flags);
            off += 2;
        },
        .@"error" => |m| {
            out[off] = @intFromEnum(m.code);
            off += 1;
            writeU16(out, off, @intCast(m.message.len));
            off += 2;
            @memcpy(out[off..][0..m.message.len], m.message);
            off += m.message.len;
        },
    }
    assert(off == out.len);
    return out;
}

const Reader = struct {
    buf: []const u8,
    off: usize = 0,

    fn rest(self: *Reader) usize {
        return self.buf.len - self.off;
    }

    fn readByte(self: *Reader) DecodeError!u8 {
        if (self.rest() < 1) return error.Malformed;
        defer self.off += 1;
        return self.buf[self.off];
    }

    fn readU16(self: *Reader) DecodeError!u16 {
        if (self.rest() < 2) return error.Malformed;
        defer self.off += 2;
        return std.mem.readInt(u16, self.buf[self.off..][0..2], .little);
    }

    fn readU32(self: *Reader) DecodeError!u32 {
        if (self.rest() < 4) return error.Malformed;
        defer self.off += 4;
        return std.mem.readInt(u32, self.buf[self.off..][0..4], .little);
    }

    fn bytes(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.rest() < n) return error.Malformed;
        defer self.off += n;
        return self.buf[self.off..][0..n];
    }
};
/// Variable-length fields alias `buf` (zero-copy).
pub fn decode(buf: []const u8) DecodeError!Message {
    if (buf.len < 4) return error.Truncated;
    const length = std.mem.readInt(u32, buf[0..][0..4], .little);
    if (length < 2) return error.BadLength;
    if (length > max_message_len) return error.BadLength;
    if (buf.len < 4 + length) return error.Truncated;
    if (buf.len > 4 + length) return error.Trailing;
    if (buf[4] != protocol_version) return error.BadVersion;
    const tag = std.enums.fromInt(Type, buf[5]) orelse
        return error.UnknownMessage;
    var r = Reader{ .buf = buf[6..] };
    switch (tag) {
        .hello => {
            const version_min = try r.readU16();
            const version_max = try r.readU16();
            const capabilities = try r.readU16();
            const role = std.enums.fromInt(Role, try r.readByte()) orelse
                return error.Malformed;
            const id_len = try r.readU16();
            const id = try r.bytes(id_len);
            if (r.rest() != 0) return error.Malformed;
            return .{ .hello = .{
                .version_min = version_min,
                .version_max = version_max,
                .capabilities = capabilities,
                .role = role,
                .id = id,
            } };
        },
        .snapshot => {
            const state_id = try r.readU32();
            const cols = try r.readU16();
            const rows = try r.readU16();
            const cursor_x = try r.readU16();
            const cursor_y = try r.readU16();
            const flags = try r.readByte();
            const cursor_style = try r.readByte();
            const chunk_index = try r.readU16();
            const chunk_count = try r.readU16();
            const payload_len = try r.readU32();
            const payload = try r.bytes(payload_len);
            if (r.rest() != 0) return error.Malformed;
            return .{ .snapshot = .{
                .state_id = state_id,
                .cols = cols,
                .rows = rows,
                .cursor_x = cursor_x,
                .cursor_y = cursor_y,
                .flags = flags,
                .cursor_style = cursor_style,
                .chunk_index = chunk_index,
                .chunk_count = chunk_count,
                .payload = payload,
            } };
        },
        .diff => {
            const base_state_id = try r.readU32();
            const state_id = try r.readU32();
            const span_count = try r.readU16();
            // Spans are decoded into a caller-visible slice without
            // allocation by reusing the frame tail as scratch: not
            // possible (spans are variable stride), so Diff borrows an
            // allocator-free view only for span_count == 0; otherwise
            // the caller must use decodeAlloc. Here we reject nonzero
            // spans to keep this function allocation-free.
            if (span_count != 0) return error.Malformed;
            if (r.rest() != 0) return error.Malformed;
            return .{ .diff = .{
                .base_state_id = base_state_id,
                .state_id = state_id,
                .spans = &.{},
            } };
        },
        .input => {
            const kind = std.enums.fromInt(InputKind, try r.readByte()) orelse
                return error.Malformed;
            const len = try r.readU32();
            const data = try r.bytes(len);
            if (r.rest() != 0) return error.Malformed;
            return .{ .input = .{ .kind = kind, .data = data } };
        },
        .resize => {
            const cols = try r.readU16();
            const rows = try r.readU16();
            const cell_width_px = try r.readU16();
            const cell_height_px = try r.readU16();
            const flags = try r.readByte();
            if (r.rest() != 0) return error.Malformed;
            return .{ .resize = .{
                .cols = cols,
                .rows = rows,
                .cell_width_px = cell_width_px,
                .cell_height_px = cell_height_px,
                .flags = flags,
            } };
        },
        .control => {
            const command = std.enums.fromInt(ControlCommand, try r.readByte()) orelse
                return error.Malformed;
            var c = Control{ .command = command };
            if (r.rest() > 0) {
                c.on = try r.readByte();
                c.has_on = true;
            }
            if (r.rest() != 0) return error.Malformed;
            return .{ .control = c };
        },
        .detached => {
            const reason = std.enums.fromInt(DetachReason, try r.readByte()) orelse
                return error.Malformed;
            if (r.rest() != 0) return error.Malformed;
            return .{ .detached = .{ .reason = reason } };
        },
        .telemetry => {
            const event_len = try r.readU16();
            const event = try r.bytes(event_len);
            const origin_session_id = try r.readU32();
            if (r.rest() != 0) return error.Malformed;
            return .{ .telemetry = .{
                .event = event,
                .origin_session_id = origin_session_id,
            } };
        },
        .image_chunk => {
            const image_id = try r.readU16();
            const chunk_index = try r.readU16();
            const chunk_count = try r.readU16();
            const mime = std.enums.fromInt(MimeTag, try r.readByte()) orelse
                return error.Malformed;
            const data_len = try r.readU32();
            const data = try r.bytes(data_len);
            if (r.rest() != 0) return error.Malformed;
            return .{ .image_chunk = .{
                .image_id = image_id,
                .chunk_index = chunk_index,
                .chunk_count = chunk_count,
                .mime = mime,
                .data = data,
            } };
        },
        .ack => {
            const state_id = try r.readU32();
            const seq_lo = try r.readU16();
            const flags = try r.readU16();
            if (r.rest() != 0) return error.Malformed;
            return .{ .ack = .{
                .state_id = state_id,
                .seq_lo = seq_lo,
                .flags = flags,
            } };
        },
        .@"error" => {
            const code = std.enums.fromInt(ErrorCode, try r.readByte()) orelse
                return error.Malformed;
            const message_len = try r.readU16();
            const message = try r.bytes(message_len);
            if (r.rest() != 0) return error.Malformed;
            return .{ .@"error" = .{ .code = code, .message = message } };
        },
    }
}

/// Decoded message that may own heap memory (only `diff.spans` needs
/// it). Free with `deinit`. All other fields alias the input buffer.
pub const OwnedMessage = struct {
    msg: Message,
    spans: []DiffSpan = &.{},
    alloc: Allocator = std.heap.page_allocator,
    owned: bool = false,

    pub fn deinit(self: *OwnedMessage) void {
        if (self.owned) self.alloc.free(self.spans);
        self.* = undefined;
    }
};

/// Decode exactly one frame like `decode`, but supports `diff` messages
/// with spans by allocating the span table. Free with `deinit`.
pub fn decodeAlloc(alloc: Allocator, buf: []const u8) DecodeError!OwnedMessage {
    if (buf.len < 4) return error.Truncated;
    const length = std.mem.readInt(u32, buf[0..][0..4], .little);
    if (length < 2) return error.BadLength;
    if (length > max_message_len) return error.BadLength;
    if (buf.len < 4 + length) return error.Truncated;
    if (buf.len > 4 + length) return error.Trailing;
    if (buf[4] != protocol_version) return error.BadVersion;
    const tag = std.enums.fromInt(Type, buf[5]) orelse
        return error.UnknownMessage;
    if (tag != .diff) {
        return .{ .msg = try decode(buf), .alloc = alloc };
    }
    var r = Reader{ .buf = buf[6..] };
    const base_state_id = try r.readU32();
    const state_id = try r.readU32();
    const span_count = try r.readU16();
    const spans = alloc.alloc(DiffSpan, span_count) catch
        return error.Malformed;
    errdefer alloc.free(spans);
    for (spans) |*s| {
        const start_x = try r.readU16();
        const start_y = try r.readU16();
        const cell_count = try r.readU16();
        const glyphs_len = try r.readU32();
        const glyphs = try r.bytes(glyphs_len);
        const style_len = try r.readU32();
        const style_data = try r.bytes(style_len);
        s.* = .{
            .start_x = start_x,
            .start_y = start_y,
            .cell_count = cell_count,
            .glyphs = glyphs,
            .style_data = style_data,
        };
    }
    if (r.rest() != 0) {
        alloc.free(spans);
        return error.Malformed;
    }
    return .{
        .msg = .{ .diff = .{
            .base_state_id = base_state_id,
            .state_id = state_id,
            .spans = spans,
        } },
        .spans = spans,
        .alloc = alloc,
        .owned = true,
    };
}

test "codec: hello round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const msg = Message{ .hello = .{
        .version_min = 1,
        .version_max = 1,
        .capabilities = 0x0023,
        .role = .client,
        .id = "deadbeef",
    } };
    const frame = try encode(alloc, msg);
    defer alloc.free(frame);
    // Frame layout: [len][ver][type][payload].
    try testing.expectEqual(@as(u32, 2 + 2 + 2 + 2 + 1 + 2 + 8), std.mem.readInt(u32, frame[0..][0..4], .little));
    try testing.expectEqual(protocol_version, frame[4]);
    try testing.expectEqual(@intFromEnum(Type.hello), frame[5]);
    const back = try decode(frame);
    try testing.expectEqual(msg.hello.version_min, back.hello.version_min);
    try testing.expectEqual(msg.hello.version_max, back.hello.version_max);
    try testing.expectEqual(msg.hello.capabilities, back.hello.capabilities);
    try testing.expectEqual(msg.hello.role, back.hello.role);
    try testing.expectEqualStrings(msg.hello.id, back.hello.id);
}

test "codec: snapshot round trip with payload" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const msg = Message{ .snapshot = .{
        .state_id = 42,
        .cols = 80,
        .rows = 24,
        .cursor_x = 5,
        .cursor_y = 6,
        .flags = 0b101,
        .cursor_style = 2,
        .chunk_index = 0,
        .chunk_count = 3,
        .payload = "\x01\x02\x03grid-bytes",
    } };
    const frame = try encode(alloc, msg);
    defer alloc.free(frame);
    const back = try decode(frame);
    try testing.expectEqual(msg.snapshot.state_id, back.snapshot.state_id);
    try testing.expectEqual(msg.snapshot.cols, back.snapshot.cols);
    try testing.expectEqualStrings(msg.snapshot.payload, back.snapshot.payload);
    try testing.expectEqual(msg.snapshot.flags, back.snapshot.flags);
}

test "codec: input/resize/control/detached/ack/error round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input = Message{ .input = .{ .kind = .paste, .data = "ls -la\n" } };
    const f1 = try encode(alloc, input);
    defer alloc.free(f1);
    try testing.expectEqualStrings("ls -la\n", (try decode(f1)).input.data);

    const resize = Message{ .resize = .{
        .cols = 100,
        .rows = 40,
        .cell_width_px = 9,
        .cell_height_px = 18,
        .flags = 1,
    } };
    const f2 = try encode(alloc, resize);
    defer alloc.free(f2);
    try testing.expectEqual(@as(u16, 100), (try decode(f2)).resize.cols);

    const ctl = Message{ .control = .{
        .command = .exit_when_empty,
        .on = 1,
        .has_on = true,
    } };
    const f3 = try encode(alloc, ctl);
    defer alloc.free(f3);
    const ctl_back = (try decode(f3)).control;
    try testing.expectEqual(ControlCommand.exit_when_empty, ctl_back.command);
    try testing.expect(ctl_back.has_on and ctl_back.on == 1);

    const det = Message{ .detached = .{ .reason = .taken_over } };
    const f4 = try encode(alloc, det);
    defer alloc.free(f4);
    try testing.expectEqual(DetachReason.taken_over, (try decode(f4)).detached.reason);

    const ack = Message{ .ack = .{
        .state_id = 0xFFFFFFFF,
        .seq_lo = 7,
        .flags = 0,
    } };
    const f5 = try encode(alloc, ack);
    defer alloc.free(f5);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), (try decode(f5)).ack.state_id);

    const err = Message{ .@"error" = .{ .code = .no_such_session, .message = "gone" } };
    const f6 = try encode(alloc, err);
    defer alloc.free(f6);
    const err_back = (try decode(f6)).@"error";
    try testing.expectEqual(ErrorCode.no_such_session, err_back.code);
    try testing.expectEqualStrings("gone", err_back.message);
}

test "codec: telemetry and image chunk round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const tel = Message{ .telemetry = .{
        .event = "{\"v\":1,\"type\":\"state\"}",
        .origin_session_id = 0x12345678,
    } };
    const f1 = try encode(alloc, tel);
    defer alloc.free(f1);
    const tel_back = (try decode(f1)).telemetry;
    try testing.expectEqualStrings(tel.telemetry.event, tel_back.event);
    try testing.expectEqual(tel.telemetry.origin_session_id, tel_back.origin_session_id);

    const img = Message{ .image_chunk = .{
        .image_id = 9,
        .chunk_index = 1,
        .chunk_count = 4,
        .mime = .jpeg,
        .data = "\xff\xd8fake",
    } };
    const f2 = try encode(alloc, img);
    defer alloc.free(f2);
    const img_back = (try decode(f2)).image_chunk;
    try testing.expectEqual(MimeTag.jpeg, img_back.mime);
    try testing.expectEqualStrings(img.image_chunk.data, img_back.data);
}

test "codec: diff round trip via decodeAlloc" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const spans = [_]DiffSpan{
        .{ .start_x = 0, .start_y = 0, .cell_count = 3, .glyphs = "abc", .style_data = "\x01\x02" },
        .{ .start_x = 5, .start_y = 1, .cell_count = 1, .glyphs = "é", .style_data = "" },
    };
    const msg = Message{ .diff = .{
        .base_state_id = 7,
        .state_id = 8,
        .spans = &spans,
    } };
    const frame = try encode(alloc, msg);
    defer alloc.free(frame);
    var owned = try decodeAlloc(alloc, frame);
    defer owned.deinit();
    try testing.expectEqual(@as(u32, 7), owned.msg.diff.base_state_id);
    try testing.expectEqual(@as(usize, 2), owned.msg.diff.spans.len);
    try testing.expectEqualStrings("é", owned.msg.diff.spans[1].glyphs);
    // Plain decode rejects span-carrying diffs (allocation-free).
    try testing.expectError(error.Malformed, decode(frame));
}

test "codec: rejects truncated, oversize, bad version, unknown type" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Truncated header and truncated body.
    try testing.expectError(error.Truncated, decode(&[_]u8{ 0x05, 0x00 }));
    {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u32, buf[0..][0..4], 60, .little);
        buf[4] = protocol_version;
        buf[5] = @intFromEnum(Type.ack);
        @memset(buf[6..], 0);
        try testing.expectError(error.Truncated, decode(&buf));
    }

    // Declared length above the 1 MiB cap.
    {
        var buf: [6]u8 = undefined;
        std.mem.writeInt(u32, buf[0..][0..4], max_message_len + 1, .little);
        buf[4] = protocol_version;
        buf[5] = @intFromEnum(Type.ack);
        try testing.expectError(error.BadLength, decode(&buf));
    }

    // Unknown protocol version.
    {
        const frame = try encode(alloc, .{ .ack = .{
            .state_id = 1,
            .seq_lo = 0,
            .flags = 0,
        } });
        defer alloc.free(frame);
        frame[4] = protocol_version + 1;
        try testing.expectError(error.BadVersion, decode(frame));
    }

    // Unknown message type.
    {
        var buf: [6]u8 = undefined;
        std.mem.writeInt(u32, buf[0..][0..4], 2, .little);
        buf[4] = protocol_version;
        buf[5] = 0x42;
        try testing.expectError(error.UnknownMessage, decode(&buf));
    }

    // Trailing bytes after one frame.
    {
        const frame = try encode(alloc, .{ .detached = .{ .reason = .taken_over } });
        defer alloc.free(frame);
        var with_trail = try alloc.alloc(u8, frame.len + 1);
        defer alloc.free(with_trail);
        @memcpy(with_trail[0..frame.len], frame);
        with_trail[frame.len] = 0;
        try testing.expectError(error.Trailing, decode(with_trail));
    }
}

test "codec: rejects bad enum values and short payloads" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Unknown InputKind.
    {
        const frame = try encode(alloc, .{ .input = .{ .kind = .text, .data = "x" } });
        defer alloc.free(frame);
        frame[6] = 0x09;
        try testing.expectError(error.Malformed, decode(frame));
    }

    // Unknown ControlCommand.
    {
        const frame = try encode(alloc, .{ .control = .{ .command = .detach } });
        defer alloc.free(frame);
        frame[6] = 0xFF;
        try testing.expectError(error.Malformed, decode(frame));
    }

    // Hello claiming more ID bytes than present.
    {
        const frame = try encode(alloc, .{ .hello = .{
            .version_min = 1,
            .version_max = 1,
            .capabilities = 0,
            .role = .daemon,
            .id = "",
        } });
        defer alloc.free(frame);
        // id_len field sits at offset 6+2+2+2+1 = 13.
        std.mem.writeInt(u16, frame[13..][0..2], 99, .little);
        try testing.expectError(error.Malformed, decode(frame));
    }

    // Empty buffer.
    try testing.expectError(error.Truncated, decode(&[_]u8{}));
}
