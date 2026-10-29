const std = @import("std");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const cross = @import("cross");
const socket = @import("socket.zig");
const label = @import("label.zig");
const agent = @import("agent.zig");
const agent_reply = @import("agent_reply.zig");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const signal = @import("signal.zig");
const assert = std.debug.assert;
const daemonize = @import("daemonize.zig");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const ghostty_vt = terminal.ghostty_vt;

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
pub fn clientLoop(io: std.Io, client_sock_fd: i32, env_str: []const u8, session_name: []const u8) !ClientResult {
    std.log.info("client loop fd={d}", .{client_sock_fd});
    const gpa: std.mem.Allocator = blk: {
        if (builtin.mode == .debug) {
            const GPA = std.heap.DebugAllocator(.{});
            const Static = struct {
                var gpa: GPA = .{};
            };
            break :blk Static.gpa.allocator();
        }
        break :blk std.heap.c_allocator;
    };
    defer lib_posix.close(client_sock_fd);

    try signal.openSignalPipe();
    defer signal.closeSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.WINCH));

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try lib_posix.fcntl(client_sock_fd, lib_posix.F.GETFL, 0);
    sock_flags |= lib_posix.O_NONBLOCK;
    _ = try lib_posix.fcntl(client_sock_fd, lib_posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer sock_write_buf.deinit(gpa);

    if (env_str.len > 0) {
        try ipc.appendMessage(gpa, &sock_write_buf, .EnvSet, env_str);
    }

    // Send init message with terminal size (buffered)
    const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    try ipc.appendMessage(gpa, &sock_write_buf, .Init, std.mem.asBytes(&size));

    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 4);
    defer poll_fds.deinit(gpa);

    var read_buf = try ipc.SocketBuffer.init(gpa);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer stdout_buf.deinit(gpa);

    const stdin_fd = lib_posix.STDIN_FILENO;

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const stdin_orig_flags = try lib_posix.fcntl(stdin_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags | lib_posix.O_NONBLOCK);
    defer _ = lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags) catch {};

    const detach_key_disabled = util.isDetachKeyDisabled();

    // Agent replies typed into this terminal (see agent_reply.zig). A reply
    // names its session by base64, so this session's name is compared that way.
    const encoder = std.base64.standard.Encoder;
    const sess_b64 = try gpa.alloc(u8, encoder.calcSize(session_name.len));
    defer gpa.free(sess_b64);
    _ = encoder.encode(sess_b64, session_name);
    var reply_scanner: agent_reply.Scanner = .{};
    defer reply_scanner.deinit(gpa);
    var scan_items: std.ArrayList(agent_reply.Scanner.Item) = .empty;
    defer scan_items.deinit(gpa);
    // Asks the daemon has announced and not yet resolved; a reply to anything
    // else is forwarded, since it may be for a session further downstream.
    var pending_rids: std.ArrayList(u32) = .empty;
    defer pending_rids.deinit(gpa);
    var hold_deadline_ms: ?i64 = null;
    var hold_timeout_ms: ?i32 = null;

    while (true) {
        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = stdin_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = lib_posix.POLL.IN;
        if (sock_write_buf.items.len > 0) {
            sock_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(gpa, .{
            .fd = client_sock_fd,
            .events = sock_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        if (stdout_buf.items.len > 0) {
            try poll_fds.append(gpa, .{
                .fd = lib_posix.STDOUT_FILENO,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        const poll_timeout: i32 = if (hold_deadline_ms) |deadline|
            @intCast(std.math.clamp(deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds(), 0, std.math.maxInt(i32)))
        else
            -1;
        _ = try lib_posix.poll(poll_fds.items, poll_timeout);

        // A partial reply held too long was ordinary input after all (a lone
        // Esc keypress, most often).
        if (hold_deadline_ms) |deadline| {
            if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) {
                const held = reply_scanner.flush();
                if (held.len > 0) try ipc.appendMessage(gpa, &sock_write_buf, .Input, held);
                hold_deadline_ms = null;
                hold_timeout_ms = null;
            }
        }

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe();
            const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
            try ipc.appendMessage(
                gpa,
                &sock_write_buf,
                .Resize,
                std.mem.asBytes(&next_size),
            );
        }

        // Handle stdin -> socket (Input)
        const inp_flags = (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL);
        if (poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (!detach_key_disabled and util.isCtrlBackslash(buf[0..n])) {
                        std.log.info("detach key detected", .{});
                        try ipc.appendMessage(gpa, &sock_write_buf, .Detach, "");
                    } else {
                        scan_items.clearRetainingCapacity();
                        try reply_scanner.feed(gpa, buf[0..n], &scan_items);
                        for (scan_items.items) |item| switch (item) {
                            .input => |bytes| try ipc.appendMessage(gpa, &sock_write_buf, .Input, bytes),
                            .reply => |reply| try routeAgentReply(gpa, &sock_write_buf, reply, sess_b64, pending_rids.items),
                        };
                        reply_scanner.clearReleased(gpa);
                        // Start (or restart, when the hold changes kind) the
                        // clock on held bytes.
                        const timeout = reply_scanner.holdTimeoutMs();
                        if (timeout != hold_timeout_ms) {
                            hold_timeout_ms = timeout;
                            hold_deadline_ms = if (timeout) |t| std.Io.Timestamp.now(io, .awake).toMilliseconds() + t else null;
                        }
                    }
                } else {
                    std.log.info("eof stdin", .{});
                    // EOF on stdin
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
            }
        }

        // Handle socket read (incoming Output messages from daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.IN != 0) {
            const n = read_buf.read(client_sock_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("server closed connection", .{});
                // Server closed connection
                return ClientResult{ .kind = .detach, .session_name = null };
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Output => {
                        if (msg.payload.len > 0) {
                            try stdout_buf.appendSlice(gpa, msg.payload);
                        }
                    },
                    .Resize => {
                        // daemon is asking for the client's window size usually in response
                        // to this client being set as leader.
                        const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
                        try ipc.appendMessage(
                            gpa,
                            &sock_write_buf,
                            .Resize,
                            std.mem.asBytes(&next_size),
                        );
                    },
                    .AgentPending => {
                        const rid = agentRid(gpa, msg.payload) orelse continue;
                        if (std.mem.indexOfScalar(u32, pending_rids.items, rid) == null) {
                            // Bounded: the daemon caps pending asks far below this.
                            if (pending_rids.items.len >= 64) _ = pending_rids.orderedRemove(0);
                            try pending_rids.append(gpa, rid);
                        }
                    },
                    .AgentResolved => {
                        const rid = agentRid(gpa, msg.payload) orelse continue;
                        if (std.mem.indexOfScalar(u32, pending_rids.items, rid)) |at| _ = pending_rids.orderedRemove(at);
                    },
                    .Switch => {
                        std.log.info("switch session", .{});
                        // Payload format: "session_name\ncwd" from the daemon
                        const newline_idx = std.mem.indexOfScalar(u8, msg.payload, '\n') orelse {
                            // No cwd provided (backward compat or old daemon)
                            return ClientResult{ .kind = .switch_session, .session_name = try gpa.dupe(u8, msg.payload) };
                        };
                        return ClientResult{
                            .kind = .switch_session,
                            .session_name = try gpa.dupe(u8, msg.payload[0..newline_idx]),
                            .cwd = if (newline_idx + 1 < msg.payload.len) try gpa.dupe(u8, msg.payload[newline_idx + 1 ..]) else null,
                        };
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n = lib_posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        std.log.info("connection reset or broken pipe", .{});
                        return ClientResult{ .kind = .detach, .session_name = null };
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(gpa, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0) {
            const n = lib_posix.write(lib_posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(gpa, 0, n, &[_]u8{});
            }
        }

        if (poll_fds.items[1].revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
            std.log.info("poll hup|err|nval", .{});
            return ClientResult{ .kind = .detach, .session_name = null };
        }
    }
}

/// The `rid` of an `AgentPending` / `AgentResolved` payload.
fn agentRid(gpa: std.mem.Allocator, payload: []const u8) ?u32 {
    const parsed = std.json.parseFromSlice(struct { rid: u32 }, gpa, payload, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.rid;
}

/// Sends a reply for one of this session's pending asks to the daemon, and
/// forwards any other reply untouched as input for a session downstream.
fn routeAgentReply(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    reply: agent_reply.Reply,
    sess_b64: []const u8,
    pending_rids: []const u32,
) !void {
    const ours = std.mem.eql(u8, reply.sess, sess_b64) and std.mem.indexOfScalar(u32, pending_rids, reply.rid) != null;
    if (!ours) return ipc.appendMessage(gpa, out, .Input, reply.raw);

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(reply.decision) catch return logBadReply(reply.rid);
    const decision = try gpa.alloc(u8, size);
    defer gpa.free(decision);
    decoder.decode(decision, reply.decision) catch return logBadReply(reply.rid);
    if (!(std.json.validate(gpa, decision) catch false)) return logBadReply(reply.rid);
    const payload = try std.fmt.allocPrint(
        gpa,
        "{{\"rid\":{d},\"nonce\":\"{s}\",\"decision\":{s}}}",
        .{ reply.rid, reply.nonce, decision },
    );
    defer gpa.free(payload);
    try ipc.appendMessage(gpa, out, .AgentReply, payload);
}

/// A reply for this session with an unreadable decision is consumed, not
/// forwarded: it is addressed here, and the PTY must never see it.
fn logBadReply(rid: u32) void {
    std.log.warn("dropping agent reply with an unreadable decision rid={d}", .{rid});
}

fn initTerminal(gpa: std.mem.Allocator, io: std.Io, size: ipc.Resize, cfg: *const Cfg) !ghostty_vt.Terminal {
    return ghostty_vt.Terminal.init(io, gpa, .{
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_lines = cfg.max_scrollback_lines,
        .max_scrollback_bytes = null, // Let the line limit control scrollback.
    });
}

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, gpa: std.mem.Allocator, io: std.Io, server_sock_fd: lib_posix.socket_t, pty_fd: i32) !void {
    std.log.info("daemon started session={s} pty_fd={d}", .{ daemon.session_name, pty_fd });

    try signal.openSignalPipe();
    signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 8);
    defer poll_fds.deinit(gpa);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try initTerminal(gpa, io, init_size, daemon.cfg);
    defer term.deinit(gpa);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();

    // Carries the tail of the previous PTY read so the task-exit marker
    // search below can see across a read() boundary. Sized to comfortably
    // hold "ZMX_TASK_COMPLETED:" (19 bytes) plus a u8 exit code and CRLF.
    var marker_carry: [32]u8 = undefined;
    var marker_carry_len: usize = 0;

    var had_terminal_client = daemon.hasTerminalClient();

    daemon_loop: while (daemon.running) {
        // If the program asked for focus reports (DECSET 1004), send focus-out
        // when the last attached client leaves and focus-in when one returns,
        // as a terminal would when its window loses/gains focus.
        const has_terminal_client = daemon.hasTerminalClient();
        if (has_terminal_client != had_terminal_client and term.modes.get(.focus_event)) {
            daemon.queuePtyInput(gpa, if (has_terminal_client) "\x1b[I" else "\x1b[O");
        }
        had_terminal_client = has_terminal_client;

        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = server_sock_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        var pty_events: i16 = lib_posix.POLL.IN;
        if (daemon.pty_write_buf.items.len > 0) {
            pty_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(gpa, .{
            .fd = pty_fd,
            .events = pty_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        for (daemon.clients.items) |client| {
            var events: i16 = lib_posix.POLL.IN;
            if (client.has_pending_output) {
                events |= lib_posix.POLL.OUT;
            }
            try poll_fds.append(gpa, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        // Wake for the next ask deadline, if any.
        _ = try lib_posix.poll(poll_fds.items, daemon.nextAskTimeoutMs(io));
        daemon.expireAsks(gpa, io);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe();
            std.log.info(
                "SIGTERM received, shutting down gracefully session={s}",
                .{daemon.session_name},
            );
            break :daemon_loop;
        }

        if (poll_fds.items[0].revents & (lib_posix.POLL.ERR | lib_posix.POLL.HUP | lib_posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & lib_posix.POLL.IN != 0) {
            const client_fd = try lib_posix.accept(
                server_sock_fd,
                null,
                null,
                lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
            );
            const client = try gpa.create(Client);
            client.* = Client{
                .alloc = gpa,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(gpa),
                .write_buf = undefined,
            };
            // 64KB initial capacity lets ~15 broadcast cycles (N_TTY_BUF_SIZE reads
            // * header) accumulate before the first ArrayList growth. The write
            // buffer is userspace-only: it drains via POLLOUT to the client socket,
            // which has no corresponding kernel-imposed per-write limit.
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 65536);
            try daemon.clients.append(gpa, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY. Buffer is sized to N_TTY_BUF_SIZE (4096): the hard
            // kernel limit for the N_TTY line discipline. A larger buffer doesn't
            // help: each read() from a PTY master returns at most 4096 bytes
            // regardless of the userspace buffer size.
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    // Let the rest of this poll iteration complete so client
                    // write buffers are flushed via the normal POLLOUT path.
                    // On the next iteration, daemon.running will be false.
                    daemon.running = false;
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    vt_stream.nextSlice(buf[0..n]);
                    daemon.passthrough.scan(gpa, buf[0..n]) catch |err| {
                        std.log.warn("agent passthrough scan failed: {s}", .{@errorName(err)});
                    };
                    // An agent in this session that reports idle on its own
                    // tty (not through `zmx agent notify`) has moved on too.
                    for (daemon.passthrough.moved_on.items) |name| daemon.cancelAgentAsks(gpa, name);
                    daemon.passthrough.clearMovedOn(gpa);
                    daemon.setPwd(&term);
                    daemon.has_pty_output = true;

                    // When no real terminal client has attached yet, respond to
                    // terminal queries (e.g. DA1/DA2) on behalf of the terminal.
                    // This prevents fish from waiting 10s for unanswered queries.
                    // Only clients that sent .Init (a real zmx attach) count,
                    // not a `zmx run` tail-only client.
                    if (!daemon.hasTerminalClient() and
                        daemon.pty_write_buf.items.len < Daemon.PTY_WRITE_BUF_MAX)
                    {
                        util.respondToDeviceAttributes(gpa, &daemon.pty_write_buf, buf[0..n]);
                    }

                    // In run mode, scan output for exit code marker. The marker
                    // can straddle two PTY reads (more likely under a throttled
                    // scheduler, e.g. containers), so prepend the tail carried
                    // over from the previous read before searching.
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        var scan_buf: [marker_carry.len + buf.len]u8 = undefined;
                        @memcpy(scan_buf[0..marker_carry_len], marker_carry[0..marker_carry_len]);
                        @memcpy(scan_buf[marker_carry_len..][0..n], buf[0..n]);
                        const scan_len = marker_carry_len + n;

                        if (try util.findTaskExitMarker(scan_buf[0..scan_len], daemon.task_id)) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

                            std.log.info("task completed exit_code={d}", .{exit_code});

                            // Notify connected clients
                            for (daemon.clients.items) |c| {
                                ipc.appendMessage(gpa, &c.write_buf, .TaskComplete, &[_]u8{exit_code}) catch {};
                                c.has_pending_output = true;
                            }
                        }

                        marker_carry_len = @min(marker_carry.len, scan_len);
                        @memcpy(
                            marker_carry[0..marker_carry_len],
                            scan_buf[scan_len - marker_carry_len .. scan_len],
                        );
                    }

                    // Broadcast data to all clients.
                    // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                    // does not clear prompt lines on resize (issue #111).
                    const broadcast_data = util.rewritePromptRedraw(gpa, buf[0..n]) orelse buf[0..n];
                    defer if (broadcast_data.ptr != buf[0..n].ptr) gpa.free(broadcast_data);
                    for (daemon.clients.items) |client| {
                        ipc.appendMessage(gpa, &client.write_buf, .Output, broadcast_data) catch |err| {
                            std.log.warn(
                                "failed to buffer output for client err={s}",
                                .{@errorName(err)},
                            );
                            continue;
                        };
                        client.has_pending_output = true;
                    }
                }
            }
        }

        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            while (daemon.pty_write_buf.items.len > 0) {
                const n = lib_posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.warn("pty write failed: {s}", .{@errorName(err)});
                        daemon.pty_write_buf.clearRetainingCapacity();
                    }
                    break;
                };
                if (n == 0) break;
                daemon.pty_write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
            }
        }

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, sig_pipe, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 3
        const num_polled_clients = poll_fds.items.len - 3;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 3].revents;

            if (revents & lib_posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Input => try daemon.handleInput(gpa, client, msg.payload),
                        .Send => daemon.handleSend(gpa, msg.payload),
                        .Output => try daemon.handleOutput(gpa, msg.payload, &term, &vt_stream),
                        .Init => try daemon.handleInit(gpa, io, client, pty_fd, &term, msg.payload),
                        .Switch => try daemon.handleSwitch(gpa, msg.payload),
                        .Resize => try daemon.handleResize(gpa, client, pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(gpa, client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll(gpa);
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => try daemon.handleInfo(gpa, client, &term),
                        .LabelGet => try daemon.handleLabelGet(gpa, client),
                        .LabelSet => try daemon.handleLabelSet(gpa, client, msg.payload),
                        .LabelClear => try daemon.handleLabelClear(gpa, client),
                        .EnvGet => try daemon.handleEnvGet(gpa, client),
                        .EnvSet => try daemon.handleEnvSet(gpa, client, msg.payload),
                        .History => try daemon.handleHistory(gpa, client, &term, msg.payload),
                        .Capture => try daemon.handleCapture(gpa, client, &term, msg.payload),
                        .Run => try daemon.handleRun(gpa, io, client, msg.payload),
                        .AgentNotify => try daemon.handleAgentNotify(gpa, io, client, msg.payload),
                        .AgentAsk => try daemon.handleAgentAsk(gpa, io, client, msg.payload),
                        .AgentReply => try daemon.handleAgentReply(gpa, client, msg.payload),
                        .AgentStateGet => try daemon.handleAgentStateGet(gpa, client),
                        .AgentSubscribe => try daemon.handleAgentSubscribe(gpa, client),
                        .Ack,
                        .TaskComplete,
                        .LabelData,
                        .EnvData,
                        .AgentPending,
                        .AgentResolved,
                        .AgentDecision,
                        .AgentStateData,
                        .Unsupported,
                        => {},
                        .Write => try daemon.handleWrite(gpa, client, msg.payload),
                        _ => {
                            std.log.warn(
                                "ignoring unknown IPC tag={d}",
                                .{@backingInt(msg.header.tag)},
                            );
                            ipc.appendMessage(gpa, &client.write_buf, .Unsupported, "") catch {};
                            client.has_pending_output = true;
                        },
                    }
                }
            }

            if (revents & lib_posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = lib_posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) {
                    client.write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
                }

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                // A client that writes and exits (`zmx send`, `zmx run -d`) is
                // reported HUP with part of its message still unread: a pass
                // reads at most 4 KiB. Closing now drops the rest. Leave it to
                // the next pass, which reads on until EOF closes the client.
                if (revents & lib_posix.POLL.IN != 0 and
                    revents & (lib_posix.POLL.ERR | lib_posix.POLL.NVAL) == 0) continue;
                const last = daemon.closeClient(gpa, client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

const ClientResult = struct {
    kind: enum {
        detach,
        switch_session,
    },
    session_name: ?[]const u8,
    cwd: ?[]const u8 = null,
};

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    is_terminal: bool = false, // sent .Init (a `zmx attach`), not a run/send/tail client
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),
    env_str: ?[]u8 = null,

    pub fn deinit(self: *Client, gpa: std.mem.Allocator) void {
        lib_posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
        if (self.env_str) |s| gpa.free(s);
    }

    fn setEnv(self: *Client, gpa: std.mem.Allocator, env_str: []const u8) !void {
        if (self.env_str) |s| gpa.free(s);
        self.env_str = if (env_str.len > 0) try gpa.dupe(u8, env_str) else null;
    }
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
pub const Daemon = struct {
    cfg: *Cfg,
    session_name: []const u8,
    socket_path: []const u8,
    // === opt ===
    pty_write_buf: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    labels: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Latest agent presence per agent, replayed to each client that attaches.
    agents: agent.Store = .{},
    /// Asks waiting for a reply, oldest first.
    asks: std.ArrayList(agent.PendingAsk) = .empty,
    next_rid: u32 = 1,
    /// Connections streaming agent events (`zmx agent events`).
    subscribers: std.ArrayList(i32) = .empty,
    /// Agent signals seen in PTY output (a nested session's, or an agent
    /// writing OSC 3008 to its tty), replayed after this session's own.
    passthrough: agent.Passthrough = .{},
    // This control which client is the leader.  The leader controls terminal state and
    // cols/rows of session.
    leader_client_fd: ?i32 = null,
    running: bool = true,
    pid: i32 = undefined,
    command: ?[]const []const u8 = null,
    /// The session's working directory in OSC 7 form, `file://<host><path>`.
    /// Kept as a URI rather than a path so `zmx list` shows the host, which is
    /// what tells you a session is inside SSH. Points into `cwd_buf` once set,
    /// so a Daemon must not be copied by value after that.
    cwd: []const u8 = "",
    /// The same directory as a path that can be opened: percent-decoding
    /// applied, scheme and host stripped. Empty when the cwd is on another
    /// host, since then it names no directory here and nothing should chdir
    /// into it. Points into `cwd_path_buf`.
    cwd_path: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    has_pty_output: bool = false,
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_id: [4]u8 = undefined,
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    pty_fd: i32 = -1, // set by daemonLoop so handleRun can probe the foreground process
    shell: []const u8 = "/bin/sh",
    quiet: bool = false,

    /// Create a Daemon. Caller is responsible for freeing all variables passed
    /// into the init fn.
    pub fn init(io: std.Io, cfg: *Cfg, sesh_name: []const u8, socket_path: []const u8) Daemon {
        return .{
            .cfg = cfg,
            .session_name = sesh_name,
            .socket_path = socket_path,
            .created_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        };
    }

    pub fn deinit(self: *Daemon, gpa: std.mem.Allocator) void {
        self.clients.deinit(gpa);
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.deinit(gpa);
        self.agents.deinit(gpa);
        for (self.asks.items) |ask| ask.deinit(gpa);
        self.asks.deinit(gpa);
        self.subscribers.deinit(gpa);
        self.passthrough.deinit(gpa);
        self.pty_write_buf.deinit(gpa);
        gpa.free(self.socket_path);
    }

    pub fn shutdown(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("shutting down daemon session={s}", .{self.session_name});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit(gpa);
            gpa.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    /// Resize the daemon's terminal with prompt_redraw disabled. On resize the
    /// terminal would clear prompt lines expecting the shell to redraw them,
    /// but the shell's redraw goes to the PTY (forwarded to clients), not to
    /// this terminal, so the clearing only corrupts our snapshot state.
    fn resizeTerm(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal, cols: u16, rows: u16) !void {
        const saved = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved;
        try term.resize(gpa, .{ .cols = cols, .rows = rows });
    }

    /// True while a client that sent .Init (a real `zmx attach`) is connected.
    fn hasTerminalClient(self: *const Daemon) bool {
        for (self.clients.items) |c| {
            if (c.is_terminal) return true;
        }
        return false;
    }

    pub fn closeClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        // leader is disconnected, remove ref and let another client claim leader on input
        if (self.leader_client_fd == client.socket_fd) {
            std.log.info(
                "unsetting leader session={s} fd={d}",
                .{ self.session_name, client.socket_fd },
            );
            self.leader_client_fd = null;
        }
        // An asker that goes away (the agent killed its hook) takes its asks
        // with it; there is no one left to tell.
        var k = self.asks.items.len;
        while (k > 0) {
            k -= 1;
            if (self.asks.items[k].asker_fd == fd) self.resolveAsk(gpa, k, .cancelled, null);
        }
        for (self.subscribers.items, 0..) |sub_fd, j| {
            if (sub_fd == fd) {
                _ = self.subscribers.swapRemove(j);
                break;
            }
        }
        client.deinit(gpa);
        gpa.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown(gpa);
            return true;
        }
        return false;
    }

    /// ensureSession will either create or re-use the daemon used for a session.
    /// It will spin up a unix socket, double-fork the process (so it survives
    /// the terminal dying), and automatically attach the client to the ipc unix
    /// socket.
    ///
    /// The return bool value indicates if the current process is the daemon
    /// or the client since they have different behaviors post-fork.
    ///
    /// E.g. If it's the client process then we need to connect to the unix socket
    /// and run the clientLoop.  If it's the daemon then we need to bail since
    /// the daemonLoop is created inside this fn and when it returns that means
    /// the daemon stopped and needs to exit.
    pub fn ensureSession(self: *Daemon, io: std.Io) !bool {
        const sesh_name = self.session_name;
        std.log.info("ensure session session={s}", .{sesh_name});
        var dir = try std.Io.Dir.openDirAbsolute(io, self.cfg.socket_dir, .{});
        defer dir.close(io);

        const exists = try socket.sessionExists(io, dir, sesh_name);
        // if daemon is gone then we flip this to true
        var should_create = !exists;

        if (exists) {
            if (ipc.connectSession(self.socket_path)) |fd| {
                lib_posix.close(fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session={s}",
                        .{sesh_name},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(io, dir, sesh_name);
                    should_create = true;
                },
                // Connect failed for an unusual reason. The check is only to
                // decide create-vs-attach; the socket file exists, so proceed
                // to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "connect failed ({s}), proceeding to attach session={s}",
                        .{ @errorName(err), sesh_name },
                    );
                },
            }
        }

        if (!should_create) {
            return false;
        }

        return self.run(io, dir, sesh_name);
    }

    fn run(self: *Daemon, io: std.Io, dir: std.Io.Dir, sesh_name: []const u8) !bool {
        std.log.info("creating session={s}", .{sesh_name});
        const server_sock_fd: lib_posix.socket_t = try socket.createSocket(self.socket_path);
        const log_fd = if (log.log_system.file) |f| f.handle else -1;

        var keep_fds_open = [_]i32{ server_sock_fd, dir.handle, log_fd };
        const cmd = try daemonize.createCmdZ(self.shell, self.is_task_mode, self.command);

        // `cwd_path` is the decoded path, and is empty when the cwd is on
        // another host: OSC 7 crosses SSH boundaries, so a session that ssh'd
        // elsewhere reports a directory that does not exist on this machine.
        std.log.info("checking pwd={s} path={s}", .{ self.cwd, self.cwd_path });
        if (self.cwd_path.len > 0) {
            const pwd_dir = std.Io.Dir.openDirAbsolute(io, self.cwd_path, .{}) catch |err| blk: {
                std.log.warn("failed to open dir={s} err={s}", .{ self.cwd_path, @errorName(err) });
                break :blk null;
            };
            if (pwd_dir) |pdir| {
                defer std.Io.Dir.close(pdir, io);
                std.log.info("set directory dir={s}", .{self.cwd_path});
                try std.process.setCurrentDir(io, pdir);
            }
        }

        const pty_info = daemonize.daemonize(
            sesh_name,
            cmd,
            &keep_fds_open,
        ) catch |err| {
            switch (err) {
                error.IsClientProc => {
                    // send a msg to the client that the session was created.
                    if (!self.quiet) {
                        var w_buf: [2048]u8 = undefined;
                        var w = std.Io.File.stdout().writer(io, &w_buf);
                        try w.interface.print("session \"{s}\" created\n", .{sesh_name});
                        try w.interface.flush();
                    }
                    lib_posix.close(server_sock_fd);
                    return false;
                },
                else => {
                    lib_posix.close(server_sock_fd);
                    dir.deleteFile(io, self.session_name) catch {};
                    return err;
                },
            }
        };
        // =======
        // WARNING: cannot use upstream allocator or io after this point since
        // we forked the process and there's a risk of a mutex (e.g. thread-safe
        // allocator) being locked by a thread prior to fork which can cause a
        // deadlock.
        // =======

        self.pid = pty_info.pid;

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const new_io = threaded.io();

        { // re-initialize logs with the session name as the filename
            log.log_system.deinit();
            var log_buf: [4096]u8 = undefined;
            const session_log_name = try std.fmt.bufPrint(
                &log_buf,
                "{s}.log",
                .{sesh_name},
            );
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const session_log_path = try std.fs.path.join(
                fba.allocator(),
                &.{ self.cfg.log_dir, session_log_name },
            );
            const log_mode = std.Io.File.Permissions.fromMode(@intCast(self.cfg.log_mode));
            log.log_system.init(new_io, session_log_path, log_mode) catch {};
        }

        const gpa: std.mem.Allocator = blk: {
            if (builtin.mode == .debug) {
                const GPA = std.heap.DebugAllocator(.{});
                const Static = struct {
                    var gpa: GPA = .{};
                };
                break :blk Static.gpa.allocator();
            }
            break :blk std.heap.c_allocator;
        };

        defer {
            // Close and unlink the listen socket BEFORE handleKill()'s
            // 500ms SIGHUP->SIGKILL grace sleep. Otherwise a `zmx run`
            // for the same name issued in that window will hang waiting
            // for a connect.
            lib_posix.close(server_sock_fd);
            std.log.info("deleting socket file session={s}", .{sesh_name});
            dir.deleteFile(new_io, sesh_name) catch |err| {
                std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
            };
            self.handleKill(gpa, new_io);
            self.deinit(gpa);
            lib_posix.close(pty_info.master_fd);
            _ = lib_posix.waitpid(self.pid, 0);
        }

        try daemonLoop(self, gpa, new_io, server_sock_fd, pty_info.master_fd);
        std.log.info("daemon loop shutdown", .{});
        return true;
    }

    fn setLeader(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        // Send a resize message to the client so it can send us back their window size
        // so we can resize the pty and ghostty state.
        try ipc.appendMessage(gpa, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
    }

    fn getLeaderClient(self: *Daemon) ?*Client {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                return client;
            }
        }
        return null;
    }

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, gpa: std.mem.Allocator, data: []const u8) void {
        if (data.len == 0) return;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return;
        }

        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{data});

        self.pty_write_buf.appendSlice(gpa, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
        };
    }

    pub fn handleInput(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{payload});

        // client is leader, send entire payload (ansi escape codes + text)
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(gpa, payload);
            return;
        }

        // check if leader needs to be updated by detecting any user input
        if (util.isUserInput(payload)) {
            try self.setLeader(gpa, client);
            self.queuePtyInput(gpa, payload);
        }
    }

    /// Queue input from `zmx send` without changing interactive client leadership.
    pub fn handleSend(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8) void {
        self.queuePtyInput(gpa, payload);
    }

    pub fn handleSwitch(self: *Daemon, gpa: std.mem.Allocator, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                // Include the daemon's current cwd so the new session can start
                // in the right directory. A remote cwd is left out: it names no
                // directory here, so the new session is better off with the
                // attaching client's own cwd than with a path it cannot enter.
                if (self.cwd.len > 0 and self.cwd_path.len > 0) {
                    var payload = gpa.alloc(u8, session_name.len + 1 + self.cwd.len) catch return;
                    defer gpa.free(payload);
                    @memcpy(payload[0..session_name.len], session_name);
                    payload[session_name.len] = '\n';
                    @memcpy(payload[session_name.len + 1 ..], self.cwd);
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, payload) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                } else {
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, session_name) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                }
                client.has_pending_output = true;
                return;
            }
        }
    }

    pub fn handleInit(
        self: *Daemon,
        gpa: std.mem.Allocator,
        io: std.Io,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;

        if (!client.is_terminal) {
            client.write_buf.clearRetainingCapacity();
            client.has_pending_output = false;
        }
        client.is_terminal = true;

        if (self.leader_client_fd == null) {
            try self.setLeader(gpa, client);
        }
        const is_leader = self.leader_client_fd == client.socket_fd;
        const resize = std.mem.bytesToValue(ipc.Resize, payload);

        if (self.has_pty_output) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (util.serializeTerminalState(gpa, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                // does not clear prompt lines on resize (issue #111).
                const restore_data = util.rewritePromptRedraw(gpa, term_output) orelse term_output;
                defer gpa.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) gpa.free(restore_data);
                ipc.appendMessage(gpa, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        // Agent presence and progress are events, not screen state, so the
        // snapshot can't carry them; replay them after it so they land on top.
        if (try self.agents.appendReplay(gpa, &client.write_buf)) {
            client.has_pending_output = true;
        }
        if (try self.passthrough.appendReplay(gpa, &client.write_buf, std.Io.Timestamp.now(io, .real).toMilliseconds())) {
            client.has_pending_output = true;
        }
        for (self.asks.items) |*ask| {
            try ipc.appendMessage(gpa, &client.write_buf, .Output, ask.osc);
            const pending = try pendingJson(gpa, ask);
            defer gpa.free(pending);
            try ipc.appendMessage(gpa, &client.write_buf, .AgentPending, pending);
            client.has_pending_output = true;
        }

        // only resize if leader
        if (is_leader) {
            // Supacode: snapshot before resizing. A surface can attach at a
            // transient placeholder size, and a snapshot laid out for it would
            // hard-wrap the restored scrollback at that width.
            try resizeTerm(gpa, term, resize.cols, resize.rows);
            var ws = resize.winsize();
            _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);

            // On re-attach, deliver SIGWINCH to the foreground process group so
            // incremental renderers (Ink, Claude Code, etc.) know to repaint.
            // If the size changed, TIOCSWINSZ above already sent SIGWINCH; if the size
            // was unchanged, the kernel suppressed it, so signal the pgrp explicitly.
            if (self.has_pty_output) {
                var pgrp: lib_posix.pid_t = 0;
                if (cross.ioctl(pty_fd, cross.TIOCGPGRP, &pgrp) == 0 and pgrp > 0) {
                    lib_posix.kill(-pgrp, .WINCH) catch {};
                }
            }

            std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
        }
    }

    pub fn handleResize(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        if (self.leader_client_fd == null) {
            try self.setLeader(gpa, client);
        }
        // only leader can resize
        if (self.leader_client_fd != client.socket_fd) return;

        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        var ws = resize.winsize();
        _ = cross.ioctl(pty_fd, cross.TIOCSWINSZ, &ws);
        try resizeTerm(gpa, term, resize.cols, resize.rows);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleDetach(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize) void {
        std.log.info("client detach session={s} fd={d}", .{ self.session_name, client.socket_fd });
        _ = self.closeClient(gpa, client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        // Go through closeClient so the leader is cleared like any other detach.
        while (self.clients.items.len > 0) {
            const last = self.clients.items.len - 1;
            _ = self.closeClient(gpa, self.clients.items[last], last, false);
        }
    }

    pub fn handleKill(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) void {
        std.log.info("kill received session={s}", .{self.session_name});
        self.shutdown(gpa);
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session={s} pid={d}", .{ self.session_name, self.pid });
        lib_posix.kill(-self.pid, lib_posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real) catch unreachable;
        lib_posix.kill(-self.pid, lib_posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
        self.setPwd(term);

        // zeroes() so asBytes() doesn't ship struct padding + unused cmd/cwd
        // tail bytes (daemon stack contents) to clients.
        var info = std.mem.zeroes(ipc.Info);
        info.protocol_version = ipc.PROTOCOL_VERSION;
        info.clients_len = self.clients.items.len - 1;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(gpa, arg) catch null
                else
                    null;
                defer if (quoted) |q| gpa.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (info.cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (info.cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(info.cmd[info.cmd_len..][0..ellipsis.len], ellipsis);
                        info.cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    info.cmd[info.cmd_len] = ' ';
                    info.cmd_len += 1;
                }
                @memcpy(info.cmd[info.cmd_len..][0..src.len], src);
                info.cmd_len += @intCast(src.len);
            }
        }

        info.cwd_len = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(info.cwd[0..info.cwd_len], self.cwd[0..info.cwd_len]);

        try ipc.appendMessage(gpa, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        self.setPwd(term);
        const format: util.HistoryFormat = if (payload.len > 0)
            @fromBackingInt(@intCast(payload[0]))
        else
            .plain;
        if (util.serializeTerminal(gpa, term, format)) |output| {
            defer gpa.free(output);
            try ipc.appendMessage(gpa, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(gpa, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleCapture(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Capture)) return;
        const request = std.mem.bytesToValue(ipc.Capture, payload);
        const format = std.enums.fromInt(util.HistoryFormat, request.format) orelse return;
        self.setPwd(term);
        const output = util.serializeTerminalRange(gpa, term, format, request.rows);
        defer if (output) |text| gpa.free(text);
        try ipc.appendMessage(gpa, &client.write_buf, .Capture, output orelse "");
        client.has_pending_output = true;
    }

    pub fn handleRun(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;
        self.task_id = util.generateTaskId(io);

        if (payload.len == 0) return;

        const cmd = payload;

        // Chain the exit marker with `;` on the same line. `$?` captures the
        // exit code of the command (not the `;`). The sole exception is when
        // the command contains a heredoc (`<<`), the delimiter must be alone
        // on its line, so the marker goes on the next line instead.
        var buf: [1024]u8 = undefined;
        const marker = try util.getTaskExitMarker(&buf, self.task_id);
        var single_buf: [1024]u8 = undefined;
        const single_line_marker = try std.fmt.bufPrint(&single_buf, "; echo {s}$?\r", .{marker});
        var here_buf: [1024]u8 = undefined;
        const heredoc_marker = try std.fmt.bufPrint(&here_buf, "\r\necho {s}$?\r", .{marker});
        const uses_heredoc = std.mem.indexOf(u8, cmd, "<<") != null;

        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(gpa, cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(gpa, cmd);
        }
        self.queuePtyInput(gpa, if (uses_heredoc) heredoc_marker else single_line_marker);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug("run command len={d}", .{payload.len});
    }

    /// Store the session's working directory as a plain path.
    ///
    /// Accepts either an OSC 7 value (`file://<host><path>`, percent-encoded)
    /// or a path. Decoding here rather than at each use keeps `zmx list`
    /// printing a path and lets the chdir on session create find directories
    /// whose names needed escaping.
    ///
    /// The value is copied, so callers may pass a temporary.
    pub fn setCwd(self: *Daemon, value: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&host_buf) catch "";
        const cwd = util.parseOsc7Cwd(&buf, value, hostname) orelse {
            std.log.warn("ignoring unusable cwd={s}", .{value});
            return;
        };

        // Store the URI form. A caller that handed us a plain path gets one
        // built here, so `cwd` has the same shape no matter the source. A value
        // that already was a URI is kept verbatim, so `list` shows what the
        // shell actually reported.
        self.cwd = if (std.fs.path.isAbsolute(value))
            util.toOsc7Cwd(&self.cwd_buf, value, hostname) orelse return
        else blk: {
            if (value.len > self.cwd_buf.len) return;
            @memcpy(self.cwd_buf[0..value.len], value);
            break :blk self.cwd_buf[0..value.len];
        };

        // Only keep an openable path when it names a directory on this host.
        if (cwd.is_local and cwd.path.len <= self.cwd_path_buf.len) {
            @memcpy(self.cwd_path_buf[0..cwd.path.len], cwd.path);
            self.cwd_path = self.cwd_path_buf[0..cwd.path.len];
        } else {
            self.cwd_path = "";
        }
        std.log.info("set cwd={s} path={s}", .{ self.cwd, self.cwd_path });
    }

    fn setPwd(self: *Daemon, term: *ghostty_vt.Terminal) void {
        const pwd = term.getPwd() orelse return;
        if (std.mem.eql(u8, self.cwd, pwd)) return;
        self.setCwd(pwd);
    }

    pub fn handleOutput(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8, term: *ghostty_vt.Terminal, vt_stream: anytype) !void {
        vt_stream.nextSlice(payload);
        self.setPwd(term);
        self.has_pty_output = true;
        for (self.clients.items) |client| {
            try ipc.appendMessage(gpa, &client.write_buf, .Output, payload);
            client.has_pending_output = true;
        }
        if (self.clients.items.len > 0) {
            lib_posix.kill(self.pid, lib_posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        // The commands skip queuePtyInput's cap: it would drop the chunks
        // past PTY_WRITE_BUF_MAX and leave the file cut short. The payload
        // is already bounded by ipc.MAX_PAYLOAD_LEN.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try gpa.alloc(u8, encoded_len);
            defer gpa.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            try self.pty_write_buf.appendSlice(gpa, "printf '%s' '");
            try self.pty_write_buf.appendSlice(gpa, encoded);
            if (is_first) {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d > '");
            } else {
                try self.pty_write_buf.appendSlice(gpa, "' | base64 -d >> '");
            }
            try self.pty_write_buf.appendSlice(gpa, file_path);
            try self.pty_write_buf.appendSlice(gpa, "'");
            try self.pty_write_buf.appendSlice(gpa, "\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        std.log.debug(
            "write command len={d} file_path={s}",
            .{ file_content.len, file_path },
        );
    }

    fn handleEnvGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const leader_opt = self.getLeaderClient();
        const payload = if (leader_opt) |leader| leader.env_str orelse "" else "";
        try ipc.appendMessage(gpa, &client.write_buf, .EnvData, payload);
        client.has_pending_output = true;
    }

    fn handleEnvSet(_: *Daemon, gpa: std.mem.Allocator, client: *Client, env_str: []const u8) !void {
        std.log.info("handle env set payload={s}", .{env_str});
        try client.setEnv(gpa, env_str);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    /// Forwards an agent event to every attached terminal as OSC 3008 and
    /// remembers presence for replay. Never fed to the terminal emulator: it
    /// is not screen content and must not reach history or snapshots. Payloads
    /// can carry prompt text, so they are not logged.
    fn handleAgentNotify(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        defer {
            ipc.appendMessage(gpa, &client.write_buf, .Ack, "") catch {};
            client.has_pending_output = true;
        }
        const parsed = agent.parse(gpa, payload) catch |err| {
            std.log.warn("dropping agent notify: {s}", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();
        const event = parsed.value;
        if (event.kind == .presence) {
            const now = std.Io.Timestamp.now(io, .real).toSeconds();
            try self.agents.record(gpa, event.agent, event.event.?, event.pid, now);
            // The agent has moved past whatever it asked: a prompt answered in
            // the terminal leaves the hook blocked until its timeout, so its
            // asks would otherwise linger. Not `busy` or `awaiting_input`,
            // which other hooks of the same tool call send alongside an ask.
            switch (event.event.?) {
                .idle, .@"error", .session_end => self.cancelAgentAsks(gpa, event.agent),
                else => {},
            }
            // A new session starts with no task list.
            if (event.event.? == .session_end) self.agents.forgetProgress(gpa, event.agent);
        }
        const osc = try agent.render(gpa, event);
        defer gpa.free(osc);
        if (event.kind == .progress) try self.agents.recordProgress(gpa, event.agent, event.total.?, osc);
        self.broadcastToTerminals(gpa, .Output, osc);
        const json = switch (event.kind) {
            .presence => try std.json.Stringify.valueAlloc(
                gpa,
                .{ .type = "presence", .agent = event.agent, .event = event.event.?, .pid = event.pid },
                .{},
            ),
            .notify => try std.json.Stringify.valueAlloc(
                gpa,
                .{ .type = "notify", .agent = event.agent, .title = event.title orelse "", .body = event.body orelse "" },
                .{},
            ),
            .progress => try std.json.Stringify.valueAlloc(
                gpa,
                .{ .type = "progress", .agent = event.agent, .done = event.done.?, .total = event.total.?, .current = event.current orelse "" },
                .{},
            ),
        };
        defer gpa.free(json);
        self.publishEvent(gpa, json);
    }

    /// Holds a request until a terminal answers it, it times out, or the
    /// asker disconnects. The asker hears back only through `AgentDecision`.
    fn handleAgentAsk(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        if (payload.len > agent.max_ask_payload) return sendDecision(gpa, client, 0, .invalid);
        const parsed = std.json.parseFromSlice(agent.AskRequest, gpa, payload, .{ .ignore_unknown_fields = true }) catch {
            return sendDecision(gpa, client, 0, .invalid);
        };
        defer parsed.deinit();
        const req = parsed.value;
        agent.validateAsk(req) catch |err| {
            std.log.warn("refusing agent ask: {s}", .{@errorName(err)});
            return sendDecision(gpa, client, 0, .invalid);
        };
        if (self.asks.items.len >= agent.max_pending_asks) return sendDecision(gpa, client, 0, .busy);

        const rid = self.next_rid;
        self.next_rid +%= 1;
        if (self.next_rid == 0) self.next_rid = 1;
        var nonce: [16]u8 = undefined;
        io.randomSecure(&nonce) catch io.random(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const detail_json = if (req.detail) |d| try std.json.Stringify.valueAlloc(gpa, d, .{}) else try gpa.dupe(u8, "");
        defer gpa.free(detail_json);
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const timeout: i64 = @intCast(std.math.clamp(req.timeout_ms, agent.min_ask_timeout_ms, agent.max_ask_timeout_ms));

        const osc = try agent.renderAsk(
            gpa,
            req.agent,
            rid,
            &nonce_hex,
            self.session_name,
            req.type,
            now + timeout,
            req.title,
            req.summary,
            detail_json,
        );
        errdefer gpa.free(osc);
        const owned_agent = try gpa.dupe(u8, req.agent);
        errdefer gpa.free(owned_agent);
        const title = try gpa.dupe(u8, req.title);
        errdefer gpa.free(title);
        const summary = try gpa.dupe(u8, req.summary);
        errdefer gpa.free(summary);
        try self.asks.append(gpa, .{
            .rid = rid,
            .nonce = nonce,
            .asker_fd = client.socket_fd,
            .agent = owned_agent,
            .type = req.type,
            .title = title,
            .summary = summary,
            .created_ms = now,
            .deadline_ms = now + timeout,
            .osc = osc,
        });
        const ask = &self.asks.items[self.asks.items.len - 1];
        std.log.info("agent ask rid={d} type={t}", .{ rid, req.type });

        self.broadcastToTerminals(gpa, .Output, osc);
        const pending = try pendingJson(gpa, ask);
        defer gpa.free(pending);
        self.broadcastToTerminals(gpa, .AgentPending, pending);
        const event = try askEventJson(gpa, ask);
        defer gpa.free(event);
        self.publishEvent(gpa, event);
    }

    /// Answers an ask. The first valid reply wins; a later one, or one with
    /// the wrong nonce, is told the rid is unknown either way, so a guess
    /// learns nothing.
    fn handleAgentReply(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        const Reply = struct { rid: u32, nonce: []const u8, decision: std.json.Value };
        const parsed = std.json.parseFromSlice(Reply, gpa, payload, .{ .ignore_unknown_fields = true }) catch {
            return ackReply(gpa, client, "invalid reply");
        };
        defer parsed.deinit();
        const reply = parsed.value;
        const index = for (self.asks.items, 0..) |ask, i| {
            if (ask.rid == reply.rid) break i;
        } else return ackReply(gpa, client, "unknown rid");
        if (!self.asks.items[index].nonceMatches(reply.nonce)) {
            std.log.warn("rejecting agent reply with a wrong nonce rid={d}", .{reply.rid});
            return ackReply(gpa, client, "unknown rid");
        }

        const decision = try std.json.Stringify.valueAlloc(gpa, reply.decision, .{});
        defer gpa.free(decision);
        if (self.clientByFd(self.asks.items[index].asker_fd)) |asker| {
            const out = try std.fmt.allocPrint(gpa, "{{\"rid\":{d},\"outcome\":\"answered\",\"decision\":{s}}}", .{ reply.rid, decision });
            defer gpa.free(out);
            try ipc.appendMessage(gpa, &asker.write_buf, .AgentDecision, out);
            asker.has_pending_output = true;
        }
        std.log.info("agent ask answered rid={d}", .{reply.rid});
        self.resolveAsk(gpa, index, .answered, null);
        return ackReply(gpa, client, null);
    }

    fn handleAgentStateGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const out = try self.agents.stateJson(gpa, self.session_name, self.asks.items);
        defer gpa.free(out);
        try ipc.appendMessage(gpa, &client.write_buf, .AgentStateData, out);
        client.has_pending_output = true;
    }

    /// Streams agent events to `client` until it disconnects, starting with
    /// the current presence and pending asks. Asks carry their nonce, so a UI
    /// outside the terminal can answer them; this is same-user access, like
    /// everything else on the socket.
    fn handleAgentSubscribe(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        for (self.subscribers.items) |fd| {
            if (fd == client.socket_fd) return;
        }
        try self.subscribers.append(gpa, client.socket_fd);
        for (self.agents.entries.items) |entry| {
            const json = try std.json.Stringify.valueAlloc(
                gpa,
                .{ .type = "presence", .agent = entry.agent, .event = entry.event, .pid = entry.pid },
                .{},
            );
            defer gpa.free(json);
            try ipc.appendMessage(gpa, &client.write_buf, .AgentStateData, json);
        }
        for (self.asks.items) |*ask| {
            const json = try askEventJson(gpa, ask);
            defer gpa.free(json);
            try ipc.appendMessage(gpa, &client.write_buf, .AgentStateData, json);
        }
        client.has_pending_output = true;
    }

    /// Removes an ask and tells everyone it is gone. `outcome` is sent to the
    /// asker when it is still listening.
    fn resolveAsk(self: *Daemon, gpa: std.mem.Allocator, index: usize, why: agent.ResolveReason, outcome: ?agent.Outcome) void {
        const ask = self.asks.orderedRemove(index);
        defer ask.deinit(gpa);
        if (outcome) |o| {
            if (self.clientByFd(ask.asker_fd)) |asker| sendDecision(gpa, asker, ask.rid, o) catch {};
        }
        if (agent.renderResolved(gpa, ask.agent, ask.rid, self.session_name, why)) |osc| {
            defer gpa.free(osc);
            self.broadcastToTerminals(gpa, .Output, osc);
        } else |_| {}
        var buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{{\"rid\":{d}}}", .{ask.rid})) |resolved| {
            self.broadcastToTerminals(gpa, .AgentResolved, resolved);
        } else |_| {}
        if (std.json.Stringify.valueAlloc(gpa, .{ .type = "resolved", .rid = ask.rid, .why = why }, .{})) |event| {
            defer gpa.free(event);
            self.publishEvent(gpa, event);
        } else |_| {}
    }

    fn cancelAgentAsks(self: *Daemon, gpa: std.mem.Allocator, agent_name: []const u8) void {
        var k = self.asks.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, self.asks.items[k].agent, agent_name)) self.resolveAsk(gpa, k, .cancelled, .cancelled);
        }
    }

    /// Milliseconds until the next ask deadline, or -1 (no timeout) with none.
    pub fn nextAskTimeoutMs(self: *const Daemon, io: std.Io) i32 {
        if (self.asks.items.len == 0) return -1;
        var next = self.asks.items[0].deadline_ms;
        for (self.asks.items[1..]) |ask| next = @min(next, ask.deadline_ms);
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        return @intCast(std.math.clamp(next - now, 0, std.math.maxInt(i32)));
    }

    pub fn expireAsks(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.asks.items.len == 0) return;
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        var k = self.asks.items.len;
        while (k > 0) {
            k -= 1;
            if (self.asks.items[k].deadline_ms <= now) {
                std.log.info("agent ask timed out rid={d}", .{self.asks.items[k].rid});
                self.resolveAsk(gpa, k, .timeout, .timeout);
            }
        }
    }

    fn clientByFd(self: *Daemon, fd: i32) ?*Client {
        for (self.clients.items) |c| {
            if (c.socket_fd == fd) return c;
        }
        return null;
    }

    fn broadcastToTerminals(self: *Daemon, gpa: std.mem.Allocator, tag: ipc.Tag, payload: []const u8) void {
        for (self.clients.items) |c| {
            if (!c.is_terminal) continue;
            ipc.appendMessage(gpa, &c.write_buf, tag, payload) catch continue;
            c.has_pending_output = true;
        }
    }

    fn publishEvent(self: *Daemon, gpa: std.mem.Allocator, json: []const u8) void {
        for (self.subscribers.items) |fd| {
            const c = self.clientByFd(fd) orelse continue;
            ipc.appendMessage(gpa, &c.write_buf, .AgentStateData, json) catch continue;
            c.has_pending_output = true;
        }
    }

    fn handleLabelGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const out = try label.labelsToU8(gpa, self.labels);
        defer gpa.free(out);
        try ipc.appendMessage(gpa, &client.write_buf, .LabelData, out);
        client.has_pending_output = true;
    }

    fn handleLabelSet(self: *Daemon, gpa: std.mem.Allocator, client: *Client, labels: []const u8) !void {
        std.log.info("handle label set payload={s}", .{labels});

        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            if (kv.value.len == 0) {
                if (self.labels.fetchRemove(kv.key)) |existing| {
                    gpa.free(existing.key);
                    gpa.free(existing.value);
                }
                continue;
            }

            const owned_key = try gpa.dupe(u8, kv.key);
            errdefer gpa.free(owned_key);
            const owned_value = try gpa.dupe(u8, kv.value);
            errdefer gpa.free(owned_value);
            if (try self.labels.fetchPut(gpa, owned_key, owned_value)) |existing| {
                // fetchPut does NOT replace the key in the map, the old
                // key pointer stays. So free the new (unused) key and the
                // old value.
                gpa.free(owned_key);
                gpa.free(existing.value);
            }
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelClear(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.clearRetainingCapacity();
        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }
};

test "terminal retains the configured scrollback without the default byte cap" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 24 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("first line\r\n");
    for (1..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");

    const history = util.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(history);
    try std.testing.expect(std.mem.startsWith(u8, history, "first line\n"));

    // Exceed the limit comfortably because Ghostty prunes whole pages.
    for (0..cfg.max_scrollback_lines) |_| stream.nextSlice("more output\r\n");
    stream.nextSlice("latest line\r\n");

    const pruned_history = util.serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(pruned_history);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "first line") == null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_history, "latest line") != null);
}

fn sendDecision(gpa: std.mem.Allocator, client: *Client, rid: u32, outcome: agent.Outcome) !void {
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{{\"rid\":{d},\"outcome\":\"{t}\"}}", .{ rid, outcome });
    try ipc.appendMessage(gpa, &client.write_buf, .AgentDecision, out);
    client.has_pending_output = true;
}

fn ackReply(gpa: std.mem.Allocator, client: *Client, err: ?[]const u8) !void {
    const out = if (err) |e|
        try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .@"error" = e }, .{})
    else
        try gpa.dupe(u8, "{\"ok\":true}");
    defer gpa.free(out);
    try ipc.appendMessage(gpa, &client.write_buf, .Ack, out);
    client.has_pending_output = true;
}

fn pendingJson(gpa: std.mem.Allocator, ask: *const agent.PendingAsk) ![]u8 {
    const nonce = ask.nonceHex();
    return std.json.Stringify.valueAlloc(gpa, .{ .rid = ask.rid, .nonce = &nonce }, .{});
}

fn askEventJson(gpa: std.mem.Allocator, ask: *const agent.PendingAsk) ![]u8 {
    const nonce = ask.nonceHex();
    return std.json.Stringify.valueAlloc(gpa, .{
        .type = "ask",
        .rid = ask.rid,
        .nonce = &nonce,
        .agent = ask.agent,
        .ask_type = ask.type,
        .title = ask.title,
        .summary = ask.summary,
        .created_ms = ask.created_ms,
        .deadline_ms = ask.deadline_ms,
    }, .{});
}

fn testDaemon() Daemon {
    return .{
        .cfg = undefined,
        .clients = .empty,
        .leader_client_fd = null,
        .session_name = "test",
        .socket_path = "",
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
}

fn testClient(alloc: std.mem.Allocator, fd: i32, is_terminal: bool) !*Client {
    const c = try alloc.create(Client);
    c.* = .{ .alloc = alloc, .socket_fd = fd, .read_buf = try ipc.SocketBuffer.init(alloc), .write_buf = .empty };
    c.is_terminal = is_terminal;
    return c;
}

test "hasTerminalClient follows attach, detach and detach-all" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);

    // Real fds (pipes) so Client.deinit's close() is legal.
    const a = try lib_posix.pipe2(.{});
    const b = try lib_posix.pipe2(.{});

    try std.testing.expect(!daemon.hasTerminalClient());

    // A run/send/tail client doesn't count.
    const tail_client = try testClient(alloc, a[0], false);
    try daemon.clients.append(alloc, tail_client);
    try std.testing.expect(!daemon.hasTerminalClient());

    // An attach client does, until it disconnects.
    const term_client = try testClient(alloc, a[1], true);
    try daemon.clients.append(alloc, term_client);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, tail_client, 0, false);
    try std.testing.expect(daemon.hasTerminalClient());
    _ = daemon.closeClient(alloc, term_client, 0, false);
    try std.testing.expect(!daemon.hasTerminalClient());

    try daemon.clients.append(alloc, try testClient(alloc, b[0], true));
    try daemon.clients.append(alloc, try testClient(alloc, b[1], true));
    daemon.handleDetachAll(alloc);
    try std.testing.expect(!daemon.hasTerminalClient());
    try std.testing.expectEqual(@as(?i32, null), daemon.leader_client_fd);
}

test "handleInit snapshots a re-attach before resizing the terminal" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 120, .rows = 10 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    // A line longer than the placeholder width the client attaches at.
    stream.nextSlice(&@as([100]u8, @splat('a')));
    stream.nextSlice("\r\nprompt$ ");

    const expected = util.serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(expected);

    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    daemon.has_pty_output = true;

    const fds = try lib_posix.pipe2(.{});
    const client = try testClient(alloc, fds[0], false);
    defer {
        client.deinit(alloc);
        alloc.destroy(client);
    }
    defer lib_posix.close(fds[1]);

    // A placeholder-sized attach must not reflow the snapshot it receives.
    const resize = ipc.Resize{ .rows = 10, .cols = 46 };
    try daemon.handleInit(alloc, std.testing.io, client, fds[1], &term, std.mem.asBytes(&resize));

    try std.testing.expectEqual(@as(u16, 46), term.cols);
    try std.testing.expect(std.mem.indexOf(u8, client.write_buf.items, expected) != null);
}

test "agent notify reaches attached terminals only, and presence replays on attach" {
    const alloc = std.testing.allocator;
    const cfg = Cfg{ .socket_dir = "", .log_dir = "" };
    var term = try initTerminal(alloc, std.testing.io, .{ .cols = 80, .rows = 10 }, &cfg);
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("prompt$ ");

    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    defer daemon.agents.deinit(alloc);
    daemon.has_pty_output = true;

    // Each client owns the read end of a pipe, closed by its deinit.
    const attached_fds = try lib_posix.pipe2(.{});
    defer lib_posix.close(attached_fds[1]);
    const attached = try testClient(alloc, attached_fds[0], true);
    defer {
        attached.deinit(alloc);
        alloc.destroy(attached);
    }
    const one_shot_fds = try lib_posix.pipe2(.{});
    defer lib_posix.close(one_shot_fds[1]);
    const one_shot = try testClient(alloc, one_shot_fds[0], false);
    defer {
        one_shot.deinit(alloc);
        alloc.destroy(one_shot);
    }
    try daemon.clients.append(alloc, attached);
    try daemon.clients.append(alloc, one_shot);

    const busy = "\x1b]3008;start=claude;event=busy\x1b\\";
    try daemon.handleAgentNotify(alloc, std.testing.io, one_shot, "{\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"busy\"}");
    try std.testing.expect(std.mem.indexOf(u8, attached.write_buf.items, busy) != null);
    // The reporter gets its Ack and nothing else.
    try std.testing.expect(std.mem.indexOf(u8, one_shot.write_buf.items, busy) == null);

    // A malformed event is acknowledged but neither forwarded nor stored.
    attached.write_buf.clearRetainingCapacity();
    try daemon.handleAgentNotify(alloc, std.testing.io, one_shot, "{\"agent\":\"claude\",\"kind\":\"presence\"}");
    try std.testing.expectEqual(@as(usize, 0), attached.write_buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), daemon.agents.entries.items.len);

    // A client attaching later gets the stored presence after its snapshot.
    const fds = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds[1]);
    const late = try testClient(alloc, fds[0], false);
    defer {
        late.deinit(alloc);
        alloc.destroy(late);
    }
    const resize = ipc.Resize{ .rows = 10, .cols = 80 };
    try daemon.handleInit(alloc, std.testing.io, late, fds[1], &term, std.mem.asBytes(&resize));
    const replay_at = std.mem.indexOf(u8, late.write_buf.items, busy) orelse return error.TestUnexpectedResult;
    const snapshot_at = std.mem.indexOf(u8, late.write_buf.items, "prompt$") orelse return error.TestUnexpectedResult;
    try std.testing.expect(snapshot_at < replay_at);
}

/// A test client on a pipe; its deinit closes the read end.
const TestPeer = struct {
    client: *Client,
    write_fd: i32,

    fn init(alloc: std.mem.Allocator, is_terminal: bool) !TestPeer {
        const fds = try lib_posix.pipe2(.{});
        return .{ .client = try testClient(alloc, fds[0], is_terminal), .write_fd = fds[1] };
    }

    fn deinit(self: TestPeer, alloc: std.mem.Allocator) void {
        self.client.deinit(alloc);
        alloc.destroy(self.client);
        lib_posix.close(self.write_fd);
    }

    /// The payload of the last frame tagged `tag` in this client's outbox.
    fn lastFrame(self: TestPeer, tag: ipc.Tag) ?[]const u8 {
        var found: ?[]const u8 = null;
        var rest = self.client.write_buf.items;
        while (rest.len >= @sizeOf(ipc.Header)) {
            const header = std.mem.bytesToValue(ipc.Header, rest[0..@sizeOf(ipc.Header)]);
            const end = @sizeOf(ipc.Header) + header.len;
            if (header.tag == tag) found = rest[@sizeOf(ipc.Header)..end];
            rest = rest[end..];
        }
        return found;
    }
};

test "agent ask: answered by the first valid reply, refused with a wrong nonce" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    defer daemon.agents.deinit(alloc);
    defer daemon.asks.deinit(alloc);
    defer daemon.subscribers.deinit(alloc);

    const viewer = try TestPeer.init(alloc, true);
    defer viewer.deinit(alloc);
    const asker = try TestPeer.init(alloc, false);
    defer asker.deinit(alloc);
    const replier = try TestPeer.init(alloc, false);
    defer replier.deinit(alloc);
    try daemon.clients.appendSlice(alloc, &.{ viewer.client, asker.client, replier.client });

    try daemon.handleAgentAsk(alloc, std.testing.io, asker.client, "{\"type\":\"permission\",\"title\":\"Bash\",\"summary\":\"make\"}");
    try std.testing.expectEqual(@as(usize, 1), daemon.asks.items.len);
    const ask = daemon.asks.items[0];
    const nonce = ask.nonceHex();
    // The viewer sees the ask; the asker hears nothing yet.
    try std.testing.expect(std.mem.indexOf(u8, viewer.client.write_buf.items, "kind=ask;rid=1;nonce=") != null);
    try std.testing.expect(viewer.lastFrame(.AgentPending) != null);
    try std.testing.expect(asker.lastFrame(.AgentDecision) == null);

    try daemon.handleAgentReply(alloc, replier.client, "{\"rid\":1,\"nonce\":\"00000000000000000000000000000000\",\"decision\":{\"behavior\":\"allow\"}}");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":\"unknown rid\"}", replier.lastFrame(.Ack).?);
    try std.testing.expectEqual(@as(usize, 1), daemon.asks.items.len);

    const good = try std.fmt.allocPrint(alloc, "{{\"rid\":1,\"nonce\":\"{s}\",\"decision\":{{\"behavior\":\"allow\"}}}}", .{&nonce});
    defer alloc.free(good);
    try daemon.handleAgentReply(alloc, replier.client, good);
    try std.testing.expectEqualStrings("{\"ok\":true}", replier.lastFrame(.Ack).?);
    try std.testing.expectEqualStrings(
        "{\"rid\":1,\"outcome\":\"answered\",\"decision\":{\"behavior\":\"allow\"}}",
        asker.lastFrame(.AgentDecision).?,
    );
    try std.testing.expectEqual(@as(usize, 0), daemon.asks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, viewer.client.write_buf.items, "kind=resolved;rid=1;sess=") != null);
    try std.testing.expectEqualStrings("{\"rid\":1}", viewer.lastFrame(.AgentResolved).?);

    // A second reply finds nothing.
    try daemon.handleAgentReply(alloc, replier.client, good);
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":\"unknown rid\"}", replier.lastFrame(.Ack).?);
}

test "agent ask: timeout, asker disconnect, and the agent moving on end it" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    defer daemon.agents.deinit(alloc);
    defer daemon.asks.deinit(alloc);
    defer daemon.subscribers.deinit(alloc);

    const viewer = try TestPeer.init(alloc, true);
    defer viewer.deinit(alloc);
    const asker = try TestPeer.init(alloc, false);
    defer asker.deinit(alloc);
    try daemon.clients.appendSlice(alloc, &.{ viewer.client, asker.client });

    // Timeout.
    try daemon.handleAgentAsk(alloc, std.testing.io, asker.client, "{\"type\":\"question\",\"timeout_ms\":1000}");
    try std.testing.expect(daemon.nextAskTimeoutMs(std.testing.io) > 0);
    daemon.asks.items[0].deadline_ms = 0;
    try std.testing.expectEqual(@as(i32, 0), daemon.nextAskTimeoutMs(std.testing.io));
    daemon.expireAsks(alloc, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), daemon.asks.items.len);
    try std.testing.expectEqualStrings("{\"rid\":1,\"outcome\":\"timeout\"}", asker.lastFrame(.AgentDecision).?);
    try std.testing.expectEqual(@as(i32, -1), daemon.nextAskTimeoutMs(std.testing.io));

    // The agent moved on: `busy` and `awaiting_input` (sent alongside an ask)
    // leave it, `idle` cancels it.
    try daemon.handleAgentAsk(alloc, std.testing.io, asker.client, "{\"type\":\"permission\"}");
    try daemon.handleAgentNotify(alloc, std.testing.io, asker.client, "{\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"busy\"}");
    try daemon.handleAgentNotify(alloc, std.testing.io, asker.client, "{\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"awaiting_input\"}");
    try daemon.handleAgentNotify(alloc, std.testing.io, asker.client, "{\"agent\":\"codex\",\"kind\":\"presence\",\"event\":\"idle\"}");
    try std.testing.expectEqual(@as(usize, 1), daemon.asks.items.len);
    try daemon.handleAgentNotify(alloc, std.testing.io, asker.client, "{\"agent\":\"claude\",\"kind\":\"presence\",\"event\":\"idle\"}");
    try std.testing.expectEqual(@as(usize, 0), daemon.asks.items.len);
    try std.testing.expectEqualStrings("{\"rid\":2,\"outcome\":\"cancelled\"}", asker.lastFrame(.AgentDecision).?);

    // The asker goes away (the agent killed its hook). closeClient frees it.
    const fds = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds[1]);
    const leaving = try testClient(alloc, fds[0], false);
    try daemon.clients.append(alloc, leaving);
    try daemon.handleAgentAsk(alloc, std.testing.io, leaving, "{\"type\":\"permission\"}");
    viewer.client.write_buf.clearRetainingCapacity();
    _ = daemon.closeClient(alloc, leaving, daemon.clients.items.len - 1, false);
    try std.testing.expectEqual(@as(usize, 0), daemon.asks.items.len);
    try std.testing.expect(std.mem.indexOf(u8, viewer.client.write_buf.items, "kind=resolved;rid=3;sess=") != null);
}

test "agent ask: refused when invalid or when too many are pending" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    defer daemon.clients.deinit(alloc);
    defer daemon.pty_write_buf.deinit(alloc);
    defer daemon.agents.deinit(alloc);
    defer {
        for (daemon.asks.items) |ask| ask.deinit(alloc);
        daemon.asks.deinit(alloc);
    }
    defer daemon.subscribers.deinit(alloc);
    const asker = try TestPeer.init(alloc, false);
    defer asker.deinit(alloc);
    try daemon.clients.append(alloc, asker.client);

    try daemon.handleAgentAsk(alloc, std.testing.io, asker.client, "{\"type\":\"dance\"}");
    try std.testing.expectEqualStrings("{\"rid\":0,\"outcome\":\"invalid\"}", asker.lastFrame(.AgentDecision).?);
    for (0..agent.max_pending_asks) |_| try daemon.handleAgentAsk(alloc, std.testing.io, asker.client, "{\"type\":\"permission\"}");
    try daemon.handleAgentAsk(alloc, std.testing.io, asker.client, "{\"type\":\"permission\"}");
    try std.testing.expectEqualStrings("{\"rid\":0,\"outcome\":\"busy\"}", asker.lastFrame(.AgentDecision).?);
}

test "send queues PTY input without changing leader" {
    const alloc = std.testing.allocator;
    var daemon = testDaemon();
    daemon.leader_client_fd = 42;
    defer daemon.pty_write_buf.deinit(alloc);

    daemon.handleSend(alloc, "hello");

    try std.testing.expectEqual(@as(?i32, 42), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("hello", daemon.pty_write_buf.items);
}

test "handleEnvGet returns leader client's environment variables including unsets" {
    const alloc = std.testing.allocator;
    var cfg = Cfg{
        .socket_dir = "/tmp",
        .log_dir = "/tmp",
    };

    var daemon = Daemon{
        .cfg = &cfg,
        .clients = .empty,
        .session_name = "test",
        .socket_path = try alloc.dupe(u8, ""),
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
    defer daemon.deinit(alloc);

    const fds1 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds1[1]);
    var client1 = Client{
        .alloc = alloc,
        .socket_fd = fds1[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client1.deinit(alloc);
    try client1.setEnv(alloc, "DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n");

    const fds2 = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds2[1]);
    var client2 = Client{
        .alloc = alloc,
        .socket_fd = fds2[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client2.deinit(alloc);
    try client2.setEnv(alloc, "SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n");

    const fds_req = try lib_posix.pipe2(.{});
    defer lib_posix.close(fds_req[1]);
    var client_req = Client{
        .alloc = alloc,
        .socket_fd = fds_req[0],
        .read_buf = try ipc.SocketBuffer.init(alloc),
        .write_buf = std.ArrayList(u8).empty,
    };
    defer client_req.deinit(alloc);

    try daemon.clients.append(alloc, &client1);
    try daemon.clients.append(alloc, &client2);

    // No leader yet -> handleEnvGet returns empty string payload
    try daemon.handleEnvGet(alloc, &client_req);
    try std.testing.expect(client_req.write_buf.items.len > 0);
    client_req.write_buf.clearRetainingCapacity();

    // Set client1 as leader
    try daemon.setLeader(alloc, &client1);
    try std.testing.expectEqual(@as(?i32, fds1[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    // Wire message: [Header][Payload]
    const pay1 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:1\nSSH_AUTH_SOCK=/tmp/ssh-1\nKITTY_LISTEN_ON=unix:/tmp/kitty-1\n-WINDOWID\n", pay1);
    client_req.write_buf.clearRetainingCapacity();

    // Switch leader to client2
    try daemon.setLeader(alloc, &client2);
    try std.testing.expectEqual(@as(?i32, fds2[0]), daemon.leader_client_fd);
    try daemon.handleEnvGet(alloc, &client_req);
    const pay2 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("SSH_AUTH_SOCK=/tmp/ssh-2\nWINDOWID=12345\nKITTY_LISTEN_ON=unix:/tmp/kitty-2\n-DISPLAY\n", pay2);
    client_req.write_buf.clearRetainingCapacity();

    // Client2 updates env
    try daemon.handleEnvSet(alloc, &client2, "DISPLAY=:99\n");
    try daemon.handleEnvGet(alloc, &client_req);
    const pay3 = client_req.write_buf.items[@sizeOf(ipc.Header)..];
    try std.testing.expectEqualStrings("DISPLAY=:99\n", pay3);
}
