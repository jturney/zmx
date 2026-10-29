//! Claude Code hook adapter for `zmx agent hook claude <permission|question>`.
//! The only Claude-specific code in zmx: it turns a hook's JSON input into an
//! agent ask and the terminal's decision back into the hook's JSON output.
//! Everything else about asks is agent-agnostic (agent.zig).
//!
//!   permission: a `PermissionRequest` hook. Output:
//!     {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{...}}}
//!   question: a `PreToolUse` hook on `AskUserQuestion`. Output:
//!     {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",
//!      "updatedInput":{...tool_input, "answers":{...}}}}
//!   progress: a `PostToolUse` hook on the task list tools (`TaskCreate`,
//!     `TaskUpdate`, `TodoWrite`) or `SessionStart`. Reports how far through
//!     its task list the agent is; never prints anything.
//! No output means "not answered", and Claude prompts in the terminal.
const std = @import("std");
const agent = @import("agent.zig");

pub const Hook = enum { permission, question, progress };

/// Longest string kept in an ask's detail; tool inputs can carry whole files.
pub const detail_string_cap = 1000;

/// What to ask, built from the hook input.
pub const Ask = struct {
    type: agent.AskType,
    title: []const u8,
    summary: []const u8,
    detail: std.json.Value,
};

/// The ask for a hook input, or null when the hook isn't one to ask about (a
/// `PreToolUse` for any tool but `AskUserQuestion`). Slices point into
/// `input` and `arena`.
pub fn askFor(arena: std.mem.Allocator, hook: Hook, input: std.json.Value) !?Ask {
    if (input != .object) return null;
    const tool = stringField(input, "tool_name") orelse return null;
    const tool_input = input.object.get("tool_input") orelse std.json.Value{ .object = .empty };
    switch (hook) {
        .progress => return null,
        .permission => return .{
            .type = .permission,
            .title = tool,
            .summary = try summarize(arena, tool, tool_input),
            .detail = try trim(arena, tool_input),
        },
        .question => {
            if (!std.mem.eql(u8, tool, "AskUserQuestion")) return null;
            const first = firstQuestion(tool_input);
            return .{
                .type = .question,
                .title = if (first) |q| stringField(q, "header") orelse "Question" else "Question",
                .summary = if (first) |q| stringField(q, "question") orelse "" else "",
                .detail = try trim(arena, tool_input),
            };
        },
    }
}

/// The hook output for a terminal's decision, or null when the decision
/// doesn't fit the hook (then Claude prompts in the terminal). Caller owns it.
pub fn output(gpa: std.mem.Allocator, hook: Hook, input: std.json.Value, decision: std.json.Value) !?[]u8 {
    if (decision != .object) return null;
    switch (hook) {
        .progress => return null,
        .permission => {
            const behavior = stringField(decision, "behavior") orelse return null;
            var out: std.json.ObjectMap = .empty;
            defer out.deinit(gpa);
            if (std.mem.eql(u8, behavior, "allow")) {
                try out.put(gpa, "behavior", .{ .string = "allow" });
                // Fields Claude accepts only for allow.
                if (decision.object.get("updatedInput")) |v| try out.put(gpa, "updatedInput", v);
                if (decision.object.get("updatedPermissions")) |v| try out.put(gpa, "updatedPermissions", v);
            } else if (std.mem.eql(u8, behavior, "deny")) {
                try out.put(gpa, "behavior", .{ .string = "deny" });
                // Fields Claude accepts only for deny.
                if (decision.object.get("message")) |v| try out.put(gpa, "message", v);
                if (decision.object.get("interrupt")) |v| try out.put(gpa, "interrupt", v);
            } else return null;
            return try std.json.Stringify.valueAlloc(gpa, .{ .hookSpecificOutput = .{
                .hookEventName = "PermissionRequest",
                .decision = std.json.Value{ .object = out },
            } }, .{});
        },
        .question => {
            const answers = decision.object.get("answers") orelse return null;
            if (answers != .object or answers.object.count() == 0) return null;
            const tool_input = input.object.get("tool_input") orelse return null;
            if (tool_input != .object) return null;
            // `updatedInput` replaces the whole input, so keep `questions`.
            var updated = try tool_input.object.clone(gpa);
            defer updated.deinit(gpa);
            try updated.put(gpa, "answers", answers);
            return try std.json.Stringify.valueAlloc(gpa, .{ .hookSpecificOutput = .{
                .hookEventName = "PreToolUse",
                .permissionDecision = "allow",
                .permissionDecisionReason = "Answered in Supacode",
                .updatedInput = std.json.Value{ .object = updated },
            } }, .{});
        },
    }
}

/// How far through its task list an agent is.
pub const Progress = struct {
    done: u32,
    total: u32,
    /// The step under way, or empty.
    current: []const u8,
};

/// Progress from a `TodoWrite` call, which carries the whole list, or null for
/// any other hook input (the task tools keep their list in files instead).
pub fn todoProgress(input: std.json.Value) ?Progress {
    if (!std.mem.eql(u8, stringField(input, "tool_name") orelse return null, "TodoWrite")) return null;
    const tool_input = input.object.get("tool_input") orelse return null;
    if (tool_input != .object) return null;
    const todos = tool_input.object.get("todos") orelse return null;
    if (todos != .array) return null;
    return progressOf(todos.array.items, "content");
}

/// Progress from the task files of Claude's task list, one JSON object each.
pub fn taskProgress(tasks: []const std.json.Value) Progress {
    return progressOf(tasks, "subject");
}

/// Counts finished items, and takes the first one under way (by `id` when
/// items carry one) as the current step, preferring its `activeForm`.
fn progressOf(items: []const std.json.Value, title_key: []const u8) Progress {
    var progress: Progress = .{ .done = 0, .total = 0, .current = "" };
    var current_id: ?u64 = null;
    for (items) |item| {
        const status = stringField(item, "status") orelse continue;
        if (std.mem.eql(u8, status, "deleted")) continue;
        progress.total += 1;
        if (std.mem.eql(u8, status, "completed")) progress.done += 1;
        if (!std.mem.eql(u8, status, "in_progress")) continue;
        const id = if (stringField(item, "id")) |id| std.fmt.parseInt(u64, id, 10) catch null else null;
        const earlier = progress.current.len == 0 or (id != null and current_id != null and id.? < current_id.?);
        if (!earlier) continue;
        current_id = id;
        progress.current = stringField(item, "activeForm") orelse stringField(item, title_key) orelse "";
    }
    return progress;
}

/// Where Claude keeps a session's task list: `<config dir>/tasks/<list id>`,
/// the list id being `CLAUDE_CODE_TASK_LIST_ID` when set, else the session id.
/// Null when the id could leave that folder. Caller owns the path.
pub fn taskListDir(gpa: std.mem.Allocator, config_dir: []const u8, list_id: []const u8) !?[]u8 {
    if (list_id.len == 0 or list_id.len > 128) return null;
    if (std.mem.eql(u8, list_id, ".") or std.mem.eql(u8, list_id, "..")) return null;
    for (list_id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return null,
    };
    return try std.fs.path.join(gpa, &.{ config_dir, "tasks", list_id });
}

/// One line for the card: what the tool is about to touch.
fn summarize(arena: std.mem.Allocator, tool: []const u8, tool_input: std.json.Value) ![]const u8 {
    const keys = [_][]const u8{ "command", "file_path", "notebook_path", "url", "pattern", "path", "query", "prompt" };
    for (keys) |key| {
        if (stringField(tool_input, key)) |v| return firstLine(v);
    }
    _ = tool;
    return firstLine(try std.json.Stringify.valueAlloc(arena, tool_input, .{}));
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn firstQuestion(tool_input: std.json.Value) ?std.json.Value {
    if (tool_input != .object) return null;
    const questions = tool_input.object.get("questions") orelse return null;
    if (questions != .array or questions.array.items.len == 0) return null;
    return questions.array.items[0];
}

fn stringField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

/// A copy of `v` with long strings cut short (on a UTF-8 boundary, marked
/// with an ellipsis), so a tool input carrying a whole file stays small.
fn trim(arena: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    switch (v) {
        .string => |s| {
            if (s.len <= detail_string_cap) return v;
            var end: usize = detail_string_cap;
            while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
            return .{ .string = try std.mem.concat(arena, u8, &.{ s[0..end], "\u{2026}" }) };
        },
        .array => |a| {
            var out = try std.json.Array.initCapacity(arena, a.items.len);
            for (a.items) |item| out.appendAssumeCapacity(try trim(arena, item));
            return .{ .array = out };
        },
        .object => |o| {
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |entry| try out.put(arena, entry.key_ptr.*, try trim(arena, entry.value_ptr.*));
            return .{ .object = out };
        },
        else => return v,
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

test "permission ask summarizes the tool call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bash = try parse(arena,
        \\{"hook_event_name":"PermissionRequest","tool_name":"Bash",
        \\ "tool_input":{"command":"rm -rf build\nmake","description":"Rebuild"}}
    );
    const ask = (try askFor(arena, .permission, bash)).?;
    try testing.expectEqual(agent.AskType.permission, ask.type);
    try testing.expectEqualStrings("Bash", ask.title);
    try testing.expectEqualStrings("rm -rf build", ask.summary);

    const edit = try parse(arena, "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/a/b.swift\",\"old_string\":\"x\"}}");
    try testing.expectEqualStrings("/a/b.swift", (try askFor(arena, .permission, edit)).?.summary);

    const other = try parse(arena, "{\"tool_name\":\"mcp__x__y\",\"tool_input\":{\"n\":1}}");
    try testing.expectEqualStrings("{\"n\":1}", (try askFor(arena, .permission, other)).?.summary);
}

test "a long tool input is trimmed in the detail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const content: [5000]u8 = @splat('x');
    const json = try std.fmt.allocPrint(arena, "{{\"tool_name\":\"Write\",\"tool_input\":{{\"file_path\":\"/f\",\"content\":\"{s}\"}}}}", .{&content});
    const ask = (try askFor(arena, .permission, try parse(arena, json))).?;
    const kept = ask.detail.object.get("content").?.string;
    try testing.expectEqual(@as(usize, detail_string_cap + "\u{2026}".len), kept.len);
    try testing.expectEqualStrings("/f", ask.detail.object.get("file_path").?.string);
}

test "question ask only for AskUserQuestion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try parse(arena,
        \\{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?",
        \\ "header":"Color","options":[{"label":"Red"},{"label":"Blue"}],"multiSelect":false}]}}
    );
    const ask = (try askFor(arena, .question, input)).?;
    try testing.expectEqual(agent.AskType.question, ask.type);
    try testing.expectEqualStrings("Color", ask.title);
    try testing.expectEqualStrings("Which color?", ask.summary);

    try testing.expectEqual(@as(?Ask, null), try askFor(arena, .question, try parse(arena, "{\"tool_name\":\"Bash\"}")));
}

test "permission output keeps only what Claude accepts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try parse(arena, "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}");

    const allow = (try output(testing.allocator, .permission, input, try parse(arena, "{\"behavior\":\"allow\",\"message\":\"ignored\"}"))).?;
    defer testing.allocator.free(allow);
    try testing.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}",
        allow,
    );

    const deny = (try output(testing.allocator, .permission, input, try parse(arena, "{\"behavior\":\"deny\",\"message\":\"no\"}"))).?;
    defer testing.allocator.free(deny);
    try testing.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"no\"}}}",
        deny,
    );

    try testing.expectEqual(@as(?[]u8, null), try output(testing.allocator, .permission, input, try parse(arena, "{\"behavior\":\"maybe\"}")));
}

test "TodoWrite progress counts its list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try parse(arena,
        \\{"tool_name":"TodoWrite","tool_input":{"todos":[
        \\ {"content":"Build","status":"completed","activeForm":"Building"},
        \\ {"content":"Test","status":"in_progress","activeForm":"Running tests"},
        \\ {"content":"Ship","status":"pending","activeForm":"Shipping"}]}}
    );
    const progress = todoProgress(input).?;
    try testing.expectEqual(@as(u32, 1), progress.done);
    try testing.expectEqual(@as(u32, 3), progress.total);
    try testing.expectEqualStrings("Running tests", progress.current);
    try testing.expectEqual(@as(?Progress, null), todoProgress(try parse(arena, "{\"tool_name\":\"TaskUpdate\"}")));
}

test "task progress takes the earliest task under way and skips deleted ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tasks = [_]std.json.Value{
        try parse(arena, "{\"id\":\"10\",\"subject\":\"Later\",\"status\":\"in_progress\"}"),
        try parse(arena, "{\"id\":\"2\",\"subject\":\"Sooner\",\"status\":\"in_progress\"}"),
        try parse(arena, "{\"id\":\"1\",\"subject\":\"Done\",\"status\":\"completed\"}"),
        try parse(arena, "{\"id\":\"3\",\"subject\":\"Gone\",\"status\":\"deleted\"}"),
    };
    const progress = taskProgress(&tasks);
    try testing.expectEqual(@as(u32, 1), progress.done);
    try testing.expectEqual(@as(u32, 3), progress.total);
    try testing.expectEqualStrings("Sooner", progress.current);
    try testing.expectEqual(@as(u32, 0), taskProgress(&.{}).total);
}

test "a task list id never leaves the tasks folder" {
    const dir = (try taskListDir(testing.allocator, "/h/.claude", "2c50820a-33b4")).?;
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings("/h/.claude/tasks/2c50820a-33b4", dir);
    try testing.expectEqual(@as(?[]u8, null), try taskListDir(testing.allocator, "/h/.claude", ".."));
    try testing.expectEqual(@as(?[]u8, null), try taskListDir(testing.allocator, "/h/.claude", "a/../b"));
    try testing.expectEqual(@as(?[]u8, null), try taskListDir(testing.allocator, "/h/.claude", ""));
}

test "question output merges the answers into the tool input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try parse(arena,
        \\{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?","options":[{"label":"Red"}]}]}}
    );
    const out = (try output(testing.allocator, .question, input, try parse(arena, "{\"answers\":{\"Which color?\":\"Red\"}}"))).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\"," ++
            "\"permissionDecisionReason\":\"Answered in Supacode\",\"updatedInput\":{\"questions\":" ++
            "[{\"question\":\"Which color?\",\"options\":[{\"label\":\"Red\"}]}],\"answers\":{\"Which color?\":\"Red\"}}}}",
        out,
    );
    try testing.expectEqual(@as(?[]u8, null), try output(testing.allocator, .question, input, try parse(arena, "{\"answers\":{}}")));
}
