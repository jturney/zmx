//! In-band replies to agent asks. A terminal answers an ask by typing an APC
//! sequence into the session's client:
//!   ESC _ zmx-reply;sess=<b64 session>;rid=<u32>;nonce=<hex32>;d=<b64 JSON> ESC \
//! (BEL also terminates). The client's stdin scanner intercepts it before it
//! reaches the daemon: a reply for this session and a pending ask is consumed
//! and sent as `AgentReply`; any other complete reply is forwarded verbatim,
//! since it may belong to a session further downstream (a nested zmx over
//! ssh). Everything that isn't a reply passes through untouched.
const std = @import("std");

pub const prefix = "\x1b_zmx-reply;";
/// Longest sequence buffered while waiting for its terminator.
pub const max_len = 4096;
/// How long a lone ESC is held before it is forwarded as ordinary input.
/// Short enough that an Esc keypress never feels delayed.
pub const escape_hold_ms: i32 = 20;
/// How long anything longer (`ESC _` onward, which no one types) is held
/// before it is given up on and forwarded, so a reply split across a slow
/// link still arrives whole while a stray prefix can't swallow keystrokes
/// for long.
pub const sequence_hold_ms: i32 = 500;

/// A complete reply sequence. Slices point into memory the scanner owns until
/// its next `clearReleased`.
pub const Reply = struct {
    /// The whole sequence, for forwarding verbatim.
    raw: []const u8,
    /// Base64 of the target session name, compared as-is.
    sess: []const u8,
    rid: u32,
    nonce: []const u8,
    /// Base64 of the decision JSON.
    decision: []const u8,
};

pub const Scanner = struct {
    held: [max_len]u8 = undefined,
    held_len: usize = 0,
    in_body: bool = false,
    /// Copies behind input released from `held`, freed by `clearReleased`.
    released: std.ArrayList([]u8) = .empty,

    /// What `feed` found in one chunk of input, in order.
    pub const Item = union(enum) {
        /// Ordinary input to forward.
        input: []const u8,
        reply: Reply,
    };

    /// Scans `input`, appending items to `out`. Items point into `input` or into
    /// copies the scanner owns; use them, then call `clearReleased`.
    pub fn feed(self: *Scanner, gpa: std.mem.Allocator, input: []const u8, out: *std.ArrayList(Item)) !void {
        var start: usize = 0; // first byte of `input` not yet forwarded or held
        var i: usize = 0;
        while (i < input.len) {
            const b = input[i];
            if (!self.in_body) {
                if (self.held_len == 0) {
                    i += 1;
                    if (b != prefix[0]) continue;
                    // Possible start of a reply: forward what came before it.
                    if (i - 1 > start) try out.append(gpa, .{ .input = input[start .. i - 1] });
                    start = i;
                    self.held[0] = b;
                    self.held_len = 1;
                    continue;
                }
                if (b == prefix[self.held_len]) {
                    i += 1;
                    start = i;
                    self.held[self.held_len] = b;
                    self.held_len += 1;
                    if (self.held_len == prefix.len) self.in_body = true;
                    continue;
                }
                // Not a reply after all: release the held bytes, then look at
                // this byte afresh (it may start a new prefix).
                try self.releaseHeld(gpa, out);
                start = i;
                continue;
            }

            if (self.held_len == max_len) {
                // Too long to be a reply; drop it rather than inject garbage.
                std.log.warn("discarding oversized agent reply sequence", .{});
                self.reset();
                start = i;
                continue;
            }
            const prev = self.held[self.held_len - 1];
            if (prev == 0x1b and b != '\\') {
                // ESC followed by anything but `\` can't be inside an APC.
                try self.releaseHeld(gpa, out);
                start = i;
                continue;
            }
            i += 1;
            start = i;
            self.held[self.held_len] = b;
            self.held_len += 1;
            const terminated = b == 0x07 or (b == '\\' and prev == 0x1b);
            if (!terminated) continue;
            const terminator_len: usize = if (b == 0x07) 1 else 2;
            // Copy it out first: the buffer is reused by the rest of this chunk.
            const copy = try gpa.dupe(u8, self.held[0..self.held_len]);
            try self.released.append(gpa, copy);
            if (parseFields(copy, copy[prefix.len .. copy.len - terminator_len])) |reply| {
                try out.append(gpa, .{ .reply = reply });
            } else {
                try out.append(gpa, .{ .input = copy });
            }
            self.reset();
        }
        if (input.len > start and !self.in_body and self.held_len == 0) {
            try out.append(gpa, .{ .input = input[start..] });
        }
    }

    /// Whether bytes are held, and for how long they may wait.
    pub fn holdTimeoutMs(self: *const Scanner) ?i32 {
        return switch (self.held_len) {
            0 => null,
            1 => escape_hold_ms,
            else => sequence_hold_ms,
        };
    }

    /// Forwards anything held (the hold timed out). The slice is valid until
    /// the next `feed` or `flush`.
    pub fn flush(self: *Scanner) []const u8 {
        const held = self.held[0..self.held_len];
        self.held_len = 0;
        self.in_body = false;
        return held;
    }

    fn reset(self: *Scanner) void {
        self.held_len = 0;
        self.in_body = false;
    }

    /// Emits the held bytes as input. They are copied, since the scanner
    /// keeps using its buffer.
    fn releaseHeld(self: *Scanner, gpa: std.mem.Allocator, out: *std.ArrayList(Item)) !void {
        if (self.held_len > 0) {
            const copy = try gpa.dupe(u8, self.held[0..self.held_len]);
            try out.append(gpa, .{ .input = copy });
            try self.released.append(gpa, copy);
        }
        self.reset();
    }

    /// Frees the copies behind released input once the caller has used them.
    pub fn clearReleased(self: *Scanner, gpa: std.mem.Allocator) void {
        for (self.released.items) |copy| gpa.free(copy);
        self.released.clearRetainingCapacity();
    }

    pub fn deinit(self: *Scanner, gpa: std.mem.Allocator) void {
        self.clearReleased(gpa);
        self.released.deinit(gpa);
    }
};

fn parseFields(raw: []const u8, body: []const u8) ?Reply {
    var sess: ?[]const u8 = null;
    var rid: ?u32 = null;
    var nonce: ?[]const u8 = null;
    var decision: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        const key = field[0..eq];
        const value = field[eq + 1 ..];
        if (std.mem.eql(u8, key, "sess")) {
            sess = value;
        } else if (std.mem.eql(u8, key, "rid")) {
            rid = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "nonce")) {
            if (value.len != 32) return null;
            nonce = value;
        } else if (std.mem.eql(u8, key, "d")) {
            decision = value;
        }
    }
    return .{
        .raw = raw,
        .sess = sess orelse return null,
        .rid = rid orelse return null,
        .nonce = nonce orelse return null,
        .decision = decision orelse return null,
    };
}

/// Formats a reply sequence. Caller owns the slice.
pub fn format(gpa: std.mem.Allocator, sess_b64: []const u8, rid: u32, nonce: []const u8, decision_json: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const d = try gpa.alloc(u8, encoder.calcSize(decision_json.len));
    defer gpa.free(d);
    _ = encoder.encode(d, decision_json);
    return std.fmt.allocPrint(gpa, "{s}sess={s};rid={d};nonce={s};d={s}\x1b\\", .{ prefix, sess_b64, rid, nonce, d });
}

/// Whether `payload` holds a complete reply sequence. Used by the daemon's
/// leader gate: a reply forwarded through a nested session is a deliberate
/// user action, not a terminal's automatic answer.
pub fn containsReply(payload: []const u8) bool {
    var rest = payload;
    while (std.mem.indexOf(u8, rest, prefix)) |at| {
        const after = rest[at + prefix.len ..];
        if (std.mem.indexOfAny(u8, after, "\x07\x1b")) |end| {
            if (after[end] == 0x07) return true;
            if (end + 1 < after.len and after[end + 1] == '\\') return true;
        }
        rest = after;
    }
    return false;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const nonce_hex = "0123456789abcdef0123456789abcdef";

/// Feeds `chunks` and returns the forwarded input and the replies' rids.
fn scan(chunks: []const []const u8) !struct { input: []u8, rids: []u32 } {
    const alloc = testing.allocator;
    var scanner: Scanner = .{};
    defer scanner.deinit(alloc);
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(alloc);
    var rids: std.ArrayList(u32) = .empty;
    errdefer rids.deinit(alloc);
    var items: std.ArrayList(Scanner.Item) = .empty;
    defer items.deinit(alloc);
    for (chunks) |chunk| {
        items.clearRetainingCapacity();
        try scanner.feed(alloc, chunk, &items);
        for (items.items) |item| switch (item) {
            .input => |bytes| try input.appendSlice(alloc, bytes),
            .reply => |r| try rids.append(alloc, r.rid),
        };
        scanner.clearReleased(alloc);
    }
    try input.appendSlice(alloc, scanner.flush());
    return .{ .input = try input.toOwnedSlice(alloc), .rids = try rids.toOwnedSlice(alloc) };
}

test "a reply is recognised at every split point and nothing leaks as input" {
    const alloc = testing.allocator;
    const seq = try format(alloc, "ZGV2", 7, nonce_hex, "{\"behavior\":\"allow\"}");
    defer alloc.free(seq);
    const stream = try std.mem.concat(alloc, u8, &.{ "ab", seq, "cd" });
    defer alloc.free(stream);
    for (0..stream.len + 1) |split| {
        const got = try scan(&.{ stream[0..split], stream[split..] });
        defer alloc.free(got.input);
        defer alloc.free(got.rids);
        try testing.expectEqualStrings("abcd", got.input);
        try testing.expectEqualSlices(u32, &.{7}, got.rids);
    }
    // One byte at a time.
    var singles: std.ArrayList([]const u8) = .empty;
    defer singles.deinit(alloc);
    for (0..stream.len) |k| try singles.append(alloc, stream[k .. k + 1]);
    const got = try scan(singles.items);
    defer alloc.free(got.input);
    defer alloc.free(got.rids);
    try testing.expectEqualStrings("abcd", got.input);
    try testing.expectEqualSlices(u32, &.{7}, got.rids);
}

test "parsed fields" {
    const alloc = testing.allocator;
    var scanner: Scanner = .{};
    defer scanner.deinit(alloc);
    var items: std.ArrayList(Scanner.Item) = .empty;
    defer items.deinit(alloc);
    try scanner.feed(alloc, "\x1b_zmx-reply;sess=ZGV2;rid=42;nonce=" ++ nonce_hex ++ ";d=e30=\x07", &items);
    try testing.expectEqual(@as(usize, 1), items.items.len);
    const r = items.items[0].reply;
    try testing.expectEqualStrings("ZGV2", r.sess);
    try testing.expectEqual(@as(u32, 42), r.rid);
    try testing.expectEqualStrings(nonce_hex, r.nonce);
    try testing.expectEqualStrings("e30=", r.decision);
}

test "escape keys and other sequences pass through" {
    const alloc = testing.allocator;
    const inputs = [_][]const u8{ "\x1b[A", "\x1bOP", "\x1b_other;x\x1b\\", "\x1b\x1b[B", "\x1b_zmx-rep\x1b[C" };
    for (inputs) |in| {
        const got = try scan(&.{in});
        defer alloc.free(got.input);
        defer alloc.free(got.rids);
        try testing.expectEqualStrings(in, got.input);
        try testing.expectEqual(@as(usize, 0), got.rids.len);
    }
}

test "a lone escape is held only until the timeout" {
    const alloc = testing.allocator;
    var scanner: Scanner = .{};
    defer scanner.deinit(alloc);
    var items: std.ArrayList(Scanner.Item) = .empty;
    defer items.deinit(alloc);
    try scanner.feed(alloc, "\x1b", &items);
    try testing.expectEqual(@as(usize, 0), items.items.len);
    try testing.expectEqual(@as(?i32, escape_hold_ms), scanner.holdTimeoutMs());
    try testing.expectEqualStrings("\x1b", scanner.flush());
    try testing.expectEqual(@as(?i32, null), scanner.holdTimeoutMs());

    // Once it is clearly an APC, it may wait longer for the rest.
    try scanner.feed(alloc, "\x1b_zm", &items);
    try testing.expectEqual(@as(?i32, sequence_hold_ms), scanner.holdTimeoutMs());
}

test "malformed and oversized sequences" {
    const alloc = testing.allocator;
    // Missing fields: forwarded verbatim, since it isn't a reply we understand.
    const missing = "\x1b_zmx-reply;sess=ZGV2;rid=1\x1b\\";
    const got = try scan(&.{missing});
    defer alloc.free(got.input);
    defer alloc.free(got.rids);
    try testing.expectEqualStrings(missing, got.input);

    // Too long: dropped, and what follows still gets through.
    const big = try alloc.alloc(u8, max_len + 10);
    defer alloc.free(big);
    @memset(big, 'x');
    @memcpy(big[0..prefix.len], prefix);
    const long = try scan(&.{ big, "ok" });
    defer alloc.free(long.input);
    defer alloc.free(long.rids);
    try testing.expect(std.mem.endsWith(u8, long.input, "ok"));
    try testing.expect(std.mem.indexOf(u8, long.input, "zmx-reply") == null);
}

test "containsReply needs a terminator" {
    try testing.expect(containsReply("x\x1b_zmx-reply;rid=1\x1b\\y"));
    try testing.expect(containsReply("\x1b_zmx-reply;rid=1\x07"));
    try testing.expect(!containsReply("\x1b_zmx-reply;rid=1"));
    try testing.expect(!containsReply("\x1b_other;x\x1b\\"));
}

test "back-to-back replies in one read keep their own fields" {
    const alloc = testing.allocator;
    const a = try format(alloc, "QQ==", 1, nonce_hex, "{\"a\":1}");
    defer alloc.free(a);
    const b = try format(alloc, "Qg==", 2, nonce_hex, "{\"b\":2}");
    defer alloc.free(b);
    const chunk = try std.mem.concat(alloc, u8, &.{ a, b, "\x1b" });
    defer alloc.free(chunk);

    var scanner: Scanner = .{};
    defer scanner.deinit(alloc);
    var items: std.ArrayList(Scanner.Item) = .empty;
    defer items.deinit(alloc);
    try scanner.feed(alloc, chunk, &items);
    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqualStrings("QQ==", items.items[0].reply.sess);
    try testing.expectEqual(@as(u32, 1), items.items[0].reply.rid);
    try testing.expectEqualStrings("Qg==", items.items[1].reply.sess);
    try testing.expectEqual(@as(u32, 2), items.items[1].reply.rid);
    // The trailing ESC is still held for the timeout.
    try testing.expectEqualStrings("\x1b", scanner.flush());
}
