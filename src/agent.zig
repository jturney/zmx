//! Agent events: a process inside a session (typically a coding agent's hook)
//! tells the session's daemon what the agent is doing, and the daemon forwards
//! it to every attached terminal as an OSC 3008 sequence and keeps the latest
//! presence per agent so a client that attaches later still sees it.
//!
//! The OSC wire format mirrors Supacode's `AgentPresenceOSC.swift` byte for
//! byte, so a stock Supacode renders these as its existing badges and
//! notifications:
//!   presence: ESC ] 3008 ; <start|end>=<agent> ; event=<event>[;pid=<pid>] ESC \
//!   notify:   ESC ] 3008 ; start=<agent> ; kind=notify;title=<b64>;body=<b64> ESC \
//! Notify text is the JSON-escaped string (no surrounding quotes), capped in
//! bytes and then standard base64, which is what Supacode decodes.
const std = @import("std");
const ipc = @import("ipc.zig");

pub const wire_version: u32 = 1;
pub const max_agent_name_len = 32;
/// Byte budgets for the escaped notify text, matching Supacode's
/// `notifyTitleByteBudget` and `notifyBodyByteBudget`.
pub const notify_title_budget = 160;
pub const notify_body_budget = 1000;
/// Agents remembered per session; the least recently updated one is dropped.
pub const max_agents = 8;

pub const Event = enum {
    session_start,
    session_end,
    busy,
    awaiting_input,
    idle,
    @"error",
    compacting,
};

pub const Kind = enum { presence, notify };

/// `AgentNotify` payload.
pub const Notify = struct {
    v: u32 = wire_version,
    agent: []const u8,
    kind: Kind,
    event: ?Event = null,
    pid: ?i32 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub const ValidationError = error{
    UnsupportedVersion,
    InvalidAgentName,
    MissingEvent,
    InvalidPid,
    EmptyNotify,
    InvalidUtf8,
};

pub fn validate(n: Notify) ValidationError!void {
    if (n.v != wire_version) return error.UnsupportedVersion;
    if (!isValidAgentName(n.agent)) return error.InvalidAgentName;
    switch (n.kind) {
        .presence => {
            if (n.event == null) return error.MissingEvent;
            // Supacode drops 0 and 1 (`kill(1, 0)` reads as alive), so never send them.
            if (n.pid) |pid| if (pid <= 1) return error.InvalidPid;
        },
        .notify => {
            const title = n.title orelse "";
            const body = n.body orelse "";
            if (title.len == 0 and body.len == 0) return error.EmptyNotify;
            if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(body)) {
                return error.InvalidUtf8;
            }
        },
    }
}

/// The OSC context id, so it may hold no `;` and stays short. Supacode's own
/// agent identifiers (`claude`, `codex`, ...) all fit.
pub fn isValidAgentName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_agent_name_len) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

pub fn parse(gpa: std.mem.Allocator, payload: []const u8) !std.json.Parsed(Notify) {
    const parsed = try std.json.parseFromSlice(Notify, gpa, payload, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

/// Renders a validated notify as its OSC 3008 sequence. Caller owns the slice.
pub fn render(gpa: std.mem.Allocator, n: Notify) ![]u8 {
    return switch (n.kind) {
        .presence => renderPresence(gpa, n.agent, n.event.?, n.pid),
        .notify => renderNotify(gpa, n.agent, n.title orelse "", n.body orelse ""),
    };
}

pub fn renderPresence(gpa: std.mem.Allocator, agent: []const u8, event: Event, pid: ?i32) ![]u8 {
    const action = if (event == .session_end) "end" else "start";
    if (pid) |p| {
        return std.fmt.allocPrint(gpa, "\x1b]3008;{s}={s};event={t};pid={d}\x1b\\", .{ action, agent, event, p });
    }
    return std.fmt.allocPrint(gpa, "\x1b]3008;{s}={s};event={t}\x1b\\", .{ action, agent, event });
}

pub fn renderNotify(gpa: std.mem.Allocator, agent: []const u8, title: []const u8, body: []const u8) ![]u8 {
    const encoded_title = try encodeNotifyText(gpa, title, notify_title_budget);
    defer gpa.free(encoded_title);
    const encoded_body = try encodeNotifyText(gpa, body, notify_body_budget);
    defer gpa.free(encoded_body);
    return std.fmt.allocPrint(
        gpa,
        "\x1b]3008;start={s};kind=notify;title={s};body={s}\x1b\\",
        .{ agent, encoded_title, encoded_body },
    );
}

/// JSON-escapes `text` (without quotes), keeps the longest prefix that fits in
/// `budget` bytes without splitting an escape or a UTF-8 sequence, and returns
/// it as standard base64. `text` must be valid UTF-8.
pub fn encodeNotifyText(gpa: std.mem.Allocator, text: []const u8, budget: usize) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var piece_buf: [6]u8 = undefined;
    while (view.nextCodepointSlice()) |slice| {
        const piece: []const u8 = if (slice.len == 1) switch (slice[0]) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => std.fmt.bufPrint(&piece_buf, "\\u{x:0>4}", .{slice[0]}) catch unreachable,
            else => slice,
        } else slice;
        if (escaped.items.len + piece.len > budget) break;
        try escaped.appendSlice(gpa, piece);
    }
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, encoder.calcSize(escaped.items.len));
    _ = encoder.encode(out, escaped.items);
    return out;
}

// ---------------------------------------------------------------------------
// Asks: a blocking request (a permission prompt, a question) that waits in
// the daemon until a terminal replies, it times out, or its asker goes away.

pub const AskType = enum { permission, question };

pub const default_ask_timeout_ms: u64 = 300_000;
pub const min_ask_timeout_ms: u64 = 1_000;
pub const max_ask_timeout_ms: u64 = 30 * 60_000;
/// Asks pending per session; more are refused with `busy`.
pub const max_pending_asks = 16;
/// Largest `AgentAsk` payload accepted (the IPC frame limit is far higher,
/// but the OSC that carries an ask is small).
pub const max_ask_payload = 64 * 1024;
/// Metadata budget for an ask's OSC, under the 2047 bytes the OSC 3008 patch
/// keeps. The detail is shed first, then the summary is shortened.
pub const ask_metadata_budget = 1900;

/// `AgentAsk` payload.
pub const AskRequest = struct {
    v: u32 = wire_version,
    agent: []const u8 = "claude",
    type: AskType,
    title: []const u8 = "",
    summary: []const u8 = "",
    /// Shown in the UI as is: the trimmed tool input or the questions.
    detail: ?std.json.Value = null,
    timeout_ms: u64 = default_ask_timeout_ms,
};

pub fn validateAsk(a: AskRequest) ValidationError!void {
    if (a.v != wire_version) return error.UnsupportedVersion;
    if (!isValidAgentName(a.agent)) return error.InvalidAgentName;
    if (!std.unicode.utf8ValidateSlice(a.title) or !std.unicode.utf8ValidateSlice(a.summary)) {
        return error.InvalidUtf8;
    }
}

/// How an ask ended, as its asker hears it (`AgentDecision.outcome`).
pub const Outcome = enum { answered, timeout, cancelled, busy, invalid };

/// Why an ask left the screen (`kind=resolved;why=`).
pub const ResolveReason = enum { answered, timeout, cancelled };

/// An ask waiting for a reply.
pub const PendingAsk = struct {
    rid: u32,
    nonce: [16]u8,
    /// The connection blocked in `zmx agent ask`; the decision goes there.
    asker_fd: i32,
    agent: []u8,
    type: AskType,
    title: []u8,
    summary: []u8,
    created_ms: i64,
    deadline_ms: i64,
    /// The rendered `kind=ask` OSC, replayed verbatim on attach.
    osc: []u8,

    pub fn deinit(self: PendingAsk, gpa: std.mem.Allocator) void {
        gpa.free(self.agent);
        gpa.free(self.title);
        gpa.free(self.summary);
        gpa.free(self.osc);
    }

    pub fn nonceHex(self: *const PendingAsk) [32]u8 {
        return std.fmt.bytesToHex(self.nonce, .lower);
    }

    /// Whether `hex` is this ask's nonce, compared in constant time.
    pub fn nonceMatches(self: *const PendingAsk, hex: []const u8) bool {
        if (hex.len != 32) return false;
        var given: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&given, hex) catch return false;
        return std.crypto.timing_safe.eql([16]u8, given, self.nonce);
    }
};

pub fn renderAsk(
    gpa: std.mem.Allocator,
    agent: []const u8,
    rid: u32,
    nonce_hex: []const u8,
    session: []const u8,
    ask_type: AskType,
    deadline_ms: i64,
    title: []const u8,
    summary: []const u8,
    detail_json: []const u8,
) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const sess = try gpa.alloc(u8, encoder.calcSize(session.len));
    defer gpa.free(sess);
    _ = encoder.encode(sess, session);
    const encoded_title = try encodeNotifyText(gpa, title, notify_title_budget);
    defer gpa.free(encoded_title);
    const head = try std.fmt.allocPrint(
        gpa,
        "kind=ask;rid={d};nonce={s};sess={s};type={t};deadline={d};title={s}",
        .{ rid, nonce_hex, sess, ask_type, deadline_ms, encoded_title },
    );
    defer gpa.free(head);

    const det = try gpa.alloc(u8, encoder.calcSize(detail_json.len));
    defer gpa.free(det);
    _ = encoder.encode(det, detail_json);
    const sum_full = try encodeNotifyText(gpa, summary, notify_body_budget);
    defer gpa.free(sum_full);

    // Everything fits: send it all.
    if (head.len + ";sum=".len + sum_full.len + ";det=".len + det.len <= ask_metadata_budget) {
        return std.fmt.allocPrint(gpa, "\x1b]3008;start={s};{s};sum={s};det={s}\x1b\\", .{ agent, head, sum_full, det });
    }
    // Shed the detail, then shorten the summary to what's left.
    const room = ask_metadata_budget -| (head.len + ";sum=".len);
    const sum = try encodeNotifyText(gpa, summary, @min(notify_body_budget, room / 4 * 3));
    defer gpa.free(sum);
    return std.fmt.allocPrint(gpa, "\x1b]3008;start={s};{s};sum={s}\x1b\\", .{ agent, head, sum });
}

/// Names the session as well as the rid, since rids are only unique within
/// one daemon and a nested chain carries several daemons' asks.
pub fn renderResolved(gpa: std.mem.Allocator, agent: []const u8, rid: u32, session: []const u8, why: ResolveReason) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const sess = try gpa.alloc(u8, encoder.calcSize(session.len));
    defer gpa.free(sess);
    _ = encoder.encode(sess, session);
    return std.fmt.allocPrint(
        gpa,
        "\x1b]3008;start={s};kind=resolved;rid={d};sess={s};why={t}\x1b\\",
        .{ agent, rid, sess, why },
    );
}

// ---------------------------------------------------------------------------
// Passthrough: agent signals that only pass through this session. When the
// session's program is itself a terminal for another session (`ssh host zmx
// attach`, or a nested `zmx attach`), the inner daemon's OSC 3008 reaches
// this one as PTY output. Nothing would replay it after this session's own
// clients reconnect, so remember the latest of each and replay it too. The
// same goes for agents that write OSC 3008 straight to their tty.

pub const osc_prefix = "\x1b]3008;";
/// Longest sequence remembered; anything longer is passed through but not kept.
pub const max_passthrough_len = 4096;
pub const max_passthrough_entries = 32;

pub const Passthrough = struct {
    /// Remembered sequences, oldest first, each under a key that a newer
    /// signal of the same kind replaces.
    entries: std.ArrayList(Entry) = .empty,
    /// A sequence (or prefix) cut off by the end of the previous read.
    partial: std.ArrayList(u8) = .empty,
    /// Whether `partial` overflowed; the rest of that sequence is skipped.
    skipping: bool = false,
    /// Whether the last byte held was ESC, which a `\\` at the start of the
    /// next read would turn into the terminator.
    tail_esc: bool = false,
    /// Agents seen reporting `idle`, `error`, or `session_end` since the
    /// caller last drained this: they have moved past anything they asked.
    moved_on: std.ArrayList([]u8) = .empty,

    pub const Entry = struct {
        key: []u8,
        osc: []u8,
        /// An ask's deadline (unix ms); past it the ask is gone even if its
        /// `resolved` never made it here (a dropped ssh link).
        deadline_ms: ?i64 = null,
    };

    pub fn deinit(self: *Passthrough, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            gpa.free(e.key);
            gpa.free(e.osc);
        }
        self.entries.deinit(gpa);
        self.partial.deinit(gpa);
        self.clearMovedOn(gpa);
        self.moved_on.deinit(gpa);
    }

    pub fn clearMovedOn(self: *Passthrough, gpa: std.mem.Allocator) void {
        for (self.moved_on.items) |name| gpa.free(name);
        self.moved_on.clearRetainingCapacity();
    }

    /// Scans one chunk of PTY output. Cheap when it holds no OSC 3008: one
    /// substring search, plus a few carried bytes at a boundary.
    pub fn scan(self: *Passthrough, gpa: std.mem.Allocator, chunk: []const u8) !void {
        var rest = chunk;

        // A possible prefix (`ESC ] 30`...) carried from the last read.
        if (!self.skipping and self.partial.items.len > 0 and self.partial.items.len < osc_prefix.len) {
            const need = osc_prefix.len - self.partial.items.len;
            const n = @min(need, rest.len);
            if (!std.mem.eql(u8, rest[0..n], osc_prefix[self.partial.items.len..][0..n])) {
                self.partial.clearRetainingCapacity(); // not a prefix after all
            } else {
                try self.partial.appendSlice(gpa, rest[0..n]);
                rest = rest[n..];
                if (n < need) return;
            }
        }

        // A sequence cut off by the last read.
        if (self.skipping or self.partial.items.len >= osc_prefix.len) {
            // The terminator may straddle the boundary: ESC then `\`.
            const end = if (self.tail_esc and rest.len > 0 and rest[0] == '\\') 1 else terminatorEnd(rest);
            if (end) |e| {
                if (!self.skipping and self.partial.items.len + e <= max_passthrough_len) {
                    try self.partial.appendSlice(gpa, rest[0..e]);
                    try self.remember(gpa, self.partial.items);
                }
                self.partial.clearRetainingCapacity();
                self.skipping = false;
                self.tail_esc = false;
                rest = rest[e..];
            } else {
                try self.hold(gpa, rest);
                return;
            }
        }

        while (std.mem.indexOf(u8, rest, osc_prefix)) |at| {
            const seq = rest[at..];
            if (terminatorEnd(seq[osc_prefix.len..])) |e| {
                const len = osc_prefix.len + e;
                if (len <= max_passthrough_len) try self.remember(gpa, seq[0..len]);
                rest = seq[len..];
            } else {
                try self.hold(gpa, seq);
                return;
            }
        }

        // Carry a trailing partial prefix into the next read.
        var keep = @min(rest.len, osc_prefix.len - 1);
        while (keep > 0) : (keep -= 1) {
            if (std.mem.startsWith(u8, osc_prefix, rest[rest.len - keep ..])) {
                try self.partial.appendSlice(gpa, rest[rest.len - keep ..]);
                return;
            }
        }
    }

    /// Keeps an unterminated sequence for the next read, or gives up on it
    /// once it is too long to be one worth remembering.
    fn hold(self: *Passthrough, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > 0) self.tail_esc = bytes[bytes.len - 1] == 0x1b;
        if (self.skipping) return;
        if (self.partial.items.len + bytes.len > max_passthrough_len) {
            self.partial.clearRetainingCapacity();
            self.skipping = true;
            return;
        }
        try self.partial.appendSlice(gpa, bytes);
    }

    /// Queues every remembered sequence as `.Output`, oldest first, first
    /// dropping asks whose deadline has passed.
    pub fn appendReplay(self: *Passthrough, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), now_ms: i64) !bool {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (e.deadline_ms != null and e.deadline_ms.? <= now_ms) {
                gpa.free(e.key);
                gpa.free(e.osc);
                _ = self.entries.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        for (self.entries.items) |e| try ipc.appendMessage(gpa, buf, .Output, e.osc);
        return self.entries.items.len > 0;
    }

    fn remember(self: *Passthrough, gpa: std.mem.Allocator, osc: []const u8) !void {
        const body = osc[osc_prefix.len .. osc.len - (if (osc[osc.len - 1] == 0x07) @as(usize, 1) else 2)];
        const semi = std.mem.indexOfScalar(u8, body, ';') orelse return;
        const id = body[0..semi];
        const metadata = body[semi + 1 ..];
        const agent_name = if (std.mem.indexOfScalar(u8, id, '=')) |eq| id[eq + 1 ..] else return;
        const kind = field(metadata, "kind");

        var key_buf: [256]u8 = undefined;
        if (kind) |k| {
            if (std.mem.eql(u8, k, "ask")) {
                const key = keyFor(&key_buf, "ask", field(metadata, "sess"), field(metadata, "rid")) orelse return;
                const deadline = if (field(metadata, "deadline")) |d| std.fmt.parseInt(i64, d, 10) catch null else null;
                return self.put(gpa, key, osc, deadline);
            }
            if (std.mem.eql(u8, k, "resolved")) {
                const key = keyFor(&key_buf, "ask", field(metadata, "sess"), field(metadata, "rid")) orelse return;
                self.remove(gpa, key);
                return;
            }
            if (std.mem.eql(u8, k, "progress")) {
                const key = keyFor(&key_buf, "progress", agent_name, "") orelse return;
                return self.put(gpa, key, osc, null);
            }
            return; // notify and unknown kinds are one-off events
        }
        const event = field(metadata, "event") orelse return;
        if (std.mem.eql(u8, event, "idle") or std.mem.eql(u8, event, "error") or std.mem.eql(u8, event, "session_end")) {
            try self.moved_on.append(gpa, try gpa.dupe(u8, agent_name));
        }
        const key = keyFor(&key_buf, "presence", agent_name, "") orelse return;
        return self.put(gpa, key, osc, null);
    }

    fn put(self: *Passthrough, gpa: std.mem.Allocator, key: []const u8, osc: []const u8, deadline_ms: ?i64) !void {
        self.remove(gpa, key);
        if (self.entries.items.len >= max_passthrough_entries) {
            const oldest = self.entries.orderedRemove(0);
            gpa.free(oldest.key);
            gpa.free(oldest.osc);
        }
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        const owned_osc = try gpa.dupe(u8, osc);
        errdefer gpa.free(owned_osc);
        try self.entries.append(gpa, .{ .key = owned_key, .osc = owned_osc, .deadline_ms = deadline_ms });
    }

    fn remove(self: *Passthrough, gpa: std.mem.Allocator, key: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                gpa.free(e.key);
                gpa.free(e.osc);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }
};

/// Index just past an OSC terminator (ST or BEL) in `bytes`, if any.
fn terminatorEnd(bytes: []const u8) ?usize {
    for (bytes, 0..) |b, i| {
        if (b == 0x07) return i + 1;
        if (b == '\\' and i > 0 and bytes[i - 1] == 0x1b) return i + 1;
    }
    return null;
}

/// The value of `key` in `k=v;k=v` metadata.
fn field(metadata: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, metadata, ';');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn keyFor(buf: []u8, kind: []const u8, a: ?[]const u8, b: ?[]const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}:{s}:{s}", .{ kind, a orelse return null, b orelse return null }) catch null;
}

/// The latest presence per agent, oldest first, for replay and `zmx agent status`.
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        agent: []u8,
        event: Event,
        pid: ?i32,
        /// Unix seconds when the daemon received it.
        at: i64,
        /// The rendered OSC, replayed verbatim on attach.
        osc: []u8,

        fn deinit(self: Entry, gpa: std.mem.Allocator) void {
            gpa.free(self.agent);
            gpa.free(self.osc);
        }
    };

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        for (self.entries.items) |entry| entry.deinit(gpa);
        self.entries.deinit(gpa);
    }

    /// Records a presence event, replacing the agent's previous one and moving
    /// it last; past `max_agents` the oldest agent is dropped.
    pub fn record(self: *Store, gpa: std.mem.Allocator, agent: []const u8, event: Event, pid: ?i32, at: i64) !void {
        const osc = try renderPresence(gpa, agent, event, pid);
        errdefer gpa.free(osc);
        const owned_agent = try gpa.dupe(u8, agent);
        errdefer gpa.free(owned_agent);
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.agent, agent)) {
                entry.deinit(gpa);
                _ = self.entries.orderedRemove(i);
                break;
            }
        }
        if (self.entries.items.len >= max_agents) {
            self.entries.items[0].deinit(gpa);
            _ = self.entries.orderedRemove(0);
        }
        try self.entries.append(gpa, .{ .agent = owned_agent, .event = event, .pid = pid, .at = at, .osc = osc });
    }

    /// Queues every stored presence as `.Output` frames, oldest first, so the
    /// most recent agent's state is the one a client applies last.
    pub fn appendReplay(self: *const Store, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !bool {
        for (self.entries.items) |entry| try ipc.appendMessage(gpa, buf, .Output, entry.osc);
        return self.entries.items.len > 0;
    }

    /// `AgentStateData` payload. Nonces are left out: anything that can ask
    /// for state could otherwise answer the asks.
    pub fn stateJson(self: *const Store, gpa: std.mem.Allocator, session: []const u8, asks: []const PendingAsk) ![]u8 {
        const AgentState = struct { agent: []const u8, event: Event, pid: ?i32, at: i64 };
        const agents = try gpa.alloc(AgentState, self.entries.items.len);
        defer gpa.free(agents);
        for (self.entries.items, agents) |entry, *out| {
            out.* = .{ .agent = entry.agent, .event = entry.event, .pid = entry.pid, .at = entry.at };
        }
        const AskState = struct {
            rid: u32,
            agent: []const u8,
            type: AskType,
            title: []const u8,
            summary: []const u8,
            created_ms: i64,
            deadline_ms: i64,
        };
        const pending = try gpa.alloc(AskState, asks.len);
        defer gpa.free(pending);
        for (asks, pending) |ask, *out| {
            out.* = .{
                .rid = ask.rid,
                .agent = ask.agent,
                .type = ask.type,
                .title = ask.title,
                .summary = ask.summary,
                .created_ms = ask.created_ms,
                .deadline_ms = ask.deadline_ms,
            };
        }
        return std.json.Stringify.valueAlloc(
            gpa,
            .{ .v = wire_version, .session = session, .agents = agents, .pending = pending },
            .{},
        );
    }
};

test "presence renders exactly what Supacode's hooks emit" {
    const alloc = std.testing.allocator;
    const busy = try renderPresence(alloc, "claude", .busy, null);
    defer alloc.free(busy);
    try std.testing.expectEqualStrings("\x1b]3008;start=claude;event=busy\x1b\\", busy);

    const with_pid = try renderPresence(alloc, "codex", .awaiting_input, 4242);
    defer alloc.free(with_pid);
    try std.testing.expectEqualStrings("\x1b]3008;start=codex;event=awaiting_input;pid=4242\x1b\\", with_pid);

    const ended = try renderPresence(alloc, "claude", .session_end, null);
    defer alloc.free(ended);
    try std.testing.expectEqualStrings("\x1b]3008;end=claude;event=session_end\x1b\\", ended);

    const failed = try renderPresence(alloc, "claude", .@"error", null);
    defer alloc.free(failed);
    try std.testing.expectEqualStrings("\x1b]3008;start=claude;event=error\x1b\\", failed);
}

test "notify text is JSON-escaped, then base64" {
    const alloc = std.testing.allocator;
    const osc = try renderNotify(alloc, "claude", "Done", "said \"hi\"\nok");
    defer alloc.free(osc);
    // base64("Done") and base64(`said \"hi\"\nok`).
    try std.testing.expectEqualStrings(
        "\x1b]3008;start=claude;kind=notify;title=RG9uZQ==;body=c2FpZCBcImhpXCJcbm9r\x1b\\",
        osc,
    );
}

test "notify text is capped without splitting an escape or a character" {
    const alloc = std.testing.allocator;
    const decoder = std.base64.standard.Decoder;
    var buf: [32]u8 = undefined;

    // "ab" + `\"` would be 4 bytes; a budget of 3 keeps only "ab".
    const quoted = try encodeNotifyText(alloc, "ab\"", 3);
    defer alloc.free(quoted);
    try decoder.decode(&buf, quoted);
    try std.testing.expectEqualStrings("ab", buf[0..try decoder.calcSizeForSlice(quoted)]);

    // "é" is two bytes; a budget of 2 after "a" fits only "a".
    const accented = try encodeNotifyText(alloc, "aé", 2);
    defer alloc.free(accented);
    try decoder.decode(&buf, accented);
    try std.testing.expectEqualStrings("a", buf[0..try decoder.calcSizeForSlice(accented)]);

    // Control characters become \uXXXX.
    const bell = try encodeNotifyText(alloc, "\x07", 16);
    defer alloc.free(bell);
    try decoder.decode(&buf, bell);
    try std.testing.expectEqualStrings("\\u0007", buf[0..try decoder.calcSizeForSlice(bell)]);
}

test "parse validates what it is given" {
    const alloc = std.testing.allocator;
    const ok = try parse(alloc, "{\"v\":1,\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"busy\",\"pid\":77,\"extra\":true}");
    defer ok.deinit();
    try std.testing.expectEqual(Event.busy, ok.value.event.?);
    try std.testing.expectEqual(@as(?i32, 77), ok.value.pid);

    try std.testing.expectError(error.MissingEvent, parse(alloc, "{\"agent\":\"claude\",\"kind\":\"presence\"}"));
    try std.testing.expectError(error.InvalidAgentName, parse(alloc, "{\"agent\":\"a;b\",\"kind\":\"presence\",\"event\":\"idle\"}"));
    try std.testing.expectError(error.InvalidPid, parse(alloc, "{\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"idle\",\"pid\":1}"));
    try std.testing.expectError(error.EmptyNotify, parse(alloc, "{\"agent\":\"claude\",\"kind\":\"notify\"}"));
    try std.testing.expectError(error.UnsupportedVersion, parse(alloc, "{\"v\":2,\"agent\":\"claude\",\"kind\":\"notify\",\"title\":\"x\"}"));
    try std.testing.expect(std.meta.isError(parse(alloc, "{\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"dancing\"}")));
}

test "store keeps the latest presence per agent, most recent last" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try store.record(alloc, "claude", .busy, null, 1);
    try store.record(alloc, "codex", .idle, null, 2);
    try store.record(alloc, "claude", .awaiting_input, 99, 3);

    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try std.testing.expectEqualStrings("codex", store.entries.items[0].agent);
    try std.testing.expectEqualStrings("claude", store.entries.items[1].agent);
    try std.testing.expectEqualStrings(
        "\x1b]3008;start=claude;event=awaiting_input;pid=99\x1b\\",
        store.entries.items[1].osc,
    );

    const json = try store.stateJson(alloc, "dev", &.{});
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"session\":\"dev\",\"agents\":[{\"agent\":\"codex\",\"event\":\"idle\",\"pid\":null,\"at\":2}," ++
            "{\"agent\":\"claude\",\"event\":\"awaiting_input\",\"pid\":99,\"at\":3}],\"pending\":[]}",
        json,
    );
}

test "store drops the least recently updated agent past its cap" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    var name_buf: [8]u8 = undefined;
    for (0..max_agents + 1) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "a{d}", .{i});
        try store.record(alloc, name, .idle, null, @intCast(i));
    }
    try std.testing.expectEqual(@as(usize, max_agents), store.entries.items.len);
    try std.testing.expectEqualStrings("a1", store.entries.items[0].agent);
}

test "ask renders its fields, shedding the detail first when too long" {
    const alloc = std.testing.allocator;
    const nonce = "0123456789abcdef0123456789abcdef";
    const small = try renderAsk(alloc, "claude", 7, nonce, "dev", .permission, 1700000000000, "Bash", "rm -rf build", "{\"command\":\"rm -rf build\"}");
    defer alloc.free(small);
    try std.testing.expectEqualStrings(
        "\x1b]3008;start=claude;kind=ask;rid=7;nonce=" ++ nonce ++ ";sess=ZGV2;type=permission;deadline=1700000000000;title=QmFzaA==;" ++
            "sum=cm0gLXJmIGJ1aWxk;det=eyJjb21tYW5kIjoicm0gLXJmIGJ1aWxkIn0=\x1b\\",
        small,
    );

    const long_summary: [900]u8 = @splat('x');
    var long_detail: [2002]u8 = @splat('y');
    long_detail[0] = '"';
    long_detail[long_detail.len - 1] = '"';
    const big = try renderAsk(alloc, "claude", 8, nonce, "dev", .question, 1700000000000, "Pick", &long_summary, &long_detail);
    defer alloc.free(big);
    try std.testing.expect(std.mem.indexOf(u8, big, ";det=") == null);
    const metadata_len = big.len - "\x1b]3008;start=claude;".len - "\x1b\\".len;
    try std.testing.expect(metadata_len <= ask_metadata_budget);
}

test "resolved names the ask and why it ended" {
    const alloc = std.testing.allocator;
    const osc = try renderResolved(alloc, "claude", 7, "dev", .timeout);
    defer alloc.free(osc);
    try std.testing.expectEqualStrings("\x1b]3008;start=claude;kind=resolved;rid=7;sess=ZGV2;why=timeout\x1b\\", osc);
}

test "nonce comparison" {
    var ask: PendingAsk = undefined;
    ask.nonce = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    try std.testing.expect(ask.nonceMatches("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!ask.nonceMatches("0123456789abcdef0123456789abcdee"));
    try std.testing.expect(!ask.nonceMatches("short"));
    try std.testing.expect(!ask.nonceMatches("zz23456789abcdef0123456789abcdef"));
}

test "passthrough remembers the latest presence and open asks, across split reads" {
    const alloc = std.testing.allocator;
    var cache: Passthrough = .{};
    defer cache.deinit(alloc);

    const busy = "\x1b]3008;start=claude;event=busy\x1b\\";
    const idle = "\x1b]3008;start=claude;event=idle\x07";
    const ask = "\x1b]3008;start=claude;kind=ask;rid=3;nonce=00;sess=Qg==;type=permission;title=eA==\x1b\\";
    const resolved = "\x1b]3008;start=claude;kind=resolved;rid=3;sess=Qg==;why=answered\x1b\\";
    const notify = "\x1b]3008;start=claude;kind=notify;title=eA==;body=eA==\x1b\\";

    const stream = "ls\r\n" ++ busy ++ "out" ++ ask ++ notify ++ "more" ++ idle ++ "$ ";
    // Every split point of the whole stream gives the same cache.
    for (0..stream.len + 1) |split| {
        var c: Passthrough = .{};
        defer c.deinit(alloc);
        try c.scan(alloc, stream[0..split]);
        try c.scan(alloc, stream[split..]);
        try std.testing.expectEqual(@as(usize, 2), c.entries.items.len);
        try std.testing.expectEqualStrings(ask, c.entries.items[0].osc);
        try std.testing.expectEqualStrings(idle, c.entries.items[1].osc);
    }

    try cache.scan(alloc, stream);
    try cache.scan(alloc, resolved);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expectEqualStrings(idle, cache.entries.items[0].osc);

    // The same rid from another session is a different ask.
    try cache.scan(alloc, ask);
    try cache.scan(alloc, "\x1b]3008;start=claude;kind=resolved;rid=3;sess=QQ==;why=answered\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
}

test "passthrough ignores other OSCs and gives up on oversized ones" {
    const alloc = std.testing.allocator;
    var cache: Passthrough = .{};
    defer cache.deinit(alloc);
    try cache.scan(alloc, "\x1b]0;title\x07\x1b]300;x\x07\x1b]30");
    try cache.scan(alloc, "08;start=claude;event=busy\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);

    // A carried ESC that turns out to be an arrow key doesn't swallow what follows.
    var fresh: Passthrough = .{};
    defer fresh.deinit(alloc);
    try fresh.scan(alloc, "\x1b");
    try fresh.scan(alloc, "[Aabc\x1b]3008;start=claude;event=busy\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), fresh.entries.items.len);

    var big: [max_passthrough_len + 100]u8 = @splat('x');
    @memcpy(big[0..osc_prefix.len], osc_prefix);
    try cache.scan(alloc, &big);
    try cache.scan(alloc, "\x1b\\\x1b]3008;start=codex;event=idle\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expectEqualStrings("presence:codex:", cache.entries.items[1].key);
}

test "passthrough keeps at most its cap, dropping the oldest" {
    const alloc = std.testing.allocator;
    var cache: Passthrough = .{};
    defer cache.deinit(alloc);
    var buf: [128]u8 = undefined;
    for (0..max_passthrough_entries + 3) |i| {
        const seq = try std.fmt.bufPrint(&buf, "\x1b]3008;start=a{d};event=busy\x1b\\", .{i});
        try cache.scan(alloc, seq);
    }
    try std.testing.expectEqual(@as(usize, max_passthrough_entries), cache.entries.items.len);
    try std.testing.expectEqualStrings("presence:a3:", cache.entries.items[0].key);
}

test "passthrough drops an ask past its deadline at replay" {
    const alloc = std.testing.allocator;
    var cache: Passthrough = .{};
    defer cache.deinit(alloc);
    try cache.scan(alloc, "\x1b]3008;start=claude;kind=ask;rid=1;nonce=00;sess=Qg==;type=permission;deadline=5000;title=eA==\x1b\\");
    try cache.scan(alloc, "\x1b]3008;start=claude;event=busy\x1b\\");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.testing.expect(try cache.appendReplay(alloc, &buf, 4999));
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    buf.clearRetainingCapacity();
    try std.testing.expect(try cache.appendReplay(alloc, &buf, 5000));
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "kind=ask") == null);
}

test "passthrough notes agents that moved on" {
    const alloc = std.testing.allocator;
    var cache: Passthrough = .{};
    defer cache.deinit(alloc);
    try cache.scan(alloc, "\x1b]3008;start=claude;event=busy\x1b\\\x1b]3008;start=claude;event=idle;pid=9\x1b\\");
    try cache.scan(alloc, "\x1b]3008;end=codex;event=session_end\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), cache.moved_on.items.len);
    try std.testing.expectEqualStrings("claude", cache.moved_on.items[0]);
    try std.testing.expectEqualStrings("codex", cache.moved_on.items[1]);
    cache.clearMovedOn(alloc);
    try std.testing.expectEqual(@as(usize, 0), cache.moved_on.items.len);
}
