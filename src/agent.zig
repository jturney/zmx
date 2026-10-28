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

    /// `AgentStateData` payload.
    pub fn stateJson(self: *const Store, gpa: std.mem.Allocator, session: []const u8) ![]u8 {
        const AgentState = struct { agent: []const u8, event: Event, pid: ?i32, at: i64 };
        const agents = try gpa.alloc(AgentState, self.entries.items.len);
        defer gpa.free(agents);
        for (self.entries.items, agents) |entry, *out| {
            out.* = .{ .agent = entry.agent, .event = entry.event, .pid = entry.pid, .at = entry.at };
        }
        return std.json.Stringify.valueAlloc(gpa, .{ .v = wire_version, .session = session, .agents = agents }, .{});
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

    const json = try store.stateJson(alloc, "dev");
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"session\":\"dev\",\"agents\":[{\"agent\":\"codex\",\"event\":\"idle\",\"pid\":null,\"at\":2}," ++
            "{\"agent\":\"claude\",\"event\":\"awaiting_input\",\"pid\":99,\"at\":3}]}",
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
