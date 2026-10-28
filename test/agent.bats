#!/usr/bin/env bats
# Agent events: `zmx agent notify|status`, forwarding as OSC 3008, and replay
# of the latest presence to clients that attach later.

load test_helper

# attach_capture <session> [hold_seconds]: connects like `zmx attach` (sends
# .Init), collects every .Output frame for a moment, and prints them with ESC
# shown as "<ESC>" so tests can grep for the OSC.
attach_capture() {
  local session="$1" hold="${2:-0.5}"
  python3 - "$ZMX_DIR" "$session" "$hold" 3>&- <<'PY'
import os, socket, struct, sys, time
sock_dir, name, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.path.join(sock_dir, name))
payload = struct.pack("<HHHH", 24, 80, 0, 0)                        # ipc.Resize
s.sendall(struct.pack("<BBHI", 7, 1, 0, len(payload)) + payload)   # .Init
s.settimeout(0.1)
data, deadline = b"", time.time() + hold
while time.time() < deadline:
    try:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    except socket.timeout:
        pass
s.close()
out = b""
while len(data) >= 8:
    tag, _ver, _res, length = struct.unpack("<BBHI", data[:8])
    if len(data) < 8 + length:
        break
    if tag == 1:                                                    # .Output
        out += data[8:8 + length]
    data = data[8 + length:]
sys.stdout.write(out.decode("utf-8", "replace").replace("\x1b", "<ESC>"))
PY
}

@test "notify records presence that status reports" {
  "$ZMX" run test-agent -d sleep 30
  wait_for_session test-agent

  run "$ZMX" agent notify --session test-agent --event busy --pid 4242
  [ "$status" -eq 0 ]

  run "$ZMX" agent status --session test-agent --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"agent":"claude","event":"busy","pid":4242'* ]]

  run "$ZMX" agent status --session test-agent
  [ "$status" -eq 0 ]
  [[ "$output" == *$'claude\tbusy\tpid=4242'* ]]
}

@test "the latest event per agent wins" {
  "$ZMX" run test-agent-latest -d sleep 30
  wait_for_session test-agent-latest

  "$ZMX" agent notify --session test-agent-latest --event busy
  "$ZMX" agent notify --session test-agent-latest --event idle
  "$ZMX" agent notify --session test-agent-latest --event busy --agent codex

  run "$ZMX" agent status --session test-agent-latest
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$output" == *$'claude\tidle'* ]]
  [[ "$output" == *$'codex\tbusy'* ]]
  [[ "$output" != *$'claude\tbusy'* ]]
}

@test "notify resolves the session from ZMX_SESSION" {
  "$ZMX" run test-agent-env -d sleep 30
  wait_for_session test-agent-env

  ZMX_SESSION=test-agent-env run "$ZMX" agent notify --event awaiting_input
  [ "$status" -eq 0 ]

  run "$ZMX" agent status --session test-agent-env
  [[ "$output" == *$'claude\tawaiting_input'* ]]
}

@test "status with no reports says so" {
  "$ZMX" run test-agent-empty -d sleep 30
  wait_for_session test-agent-empty

  run "$ZMX" agent status --session test-agent-empty
  [ "$status" -eq 0 ]
  [[ "$output" == "no agent activity" ]]
}

@test "notify never fails a hook" {
  # Outside any session.
  run env -u ZMX_SESSION "$ZMX" agent notify --event busy
  [ "$status" -eq 0 ]
  # A session that doesn't exist.
  run "$ZMX" agent notify --session no-such-session --event busy
  [ "$status" -eq 0 ]
  # Bad input warns on stderr but still exits 0.
  run "$ZMX" agent notify --session no-such-session --event dancing
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown --event"* ]]
  run "$ZMX" agent notify --session no-such-session --event busy --agent "a;b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"InvalidAgentName"* ]]
}

@test "status fails clearly for a missing session" {
  run "$ZMX" agent status --session no-such-session
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-session"* ]]
}

@test "presence replays to a client that attaches later" {
  "$ZMX" run test-agent-replay -d bash -c 'echo READY; sleep 30'
  wait_for_output test-agent-replay "READY"

  "$ZMX" agent notify --session test-agent-replay --event busy --agent codex
  "$ZMX" agent notify --session test-agent-replay --event awaiting_input --pid 4242

  run attach_capture test-agent-replay
  [ "$status" -eq 0 ]
  [[ "$output" == *"<ESC>]3008;start=codex;event=busy<ESC>\\"* ]]
  [[ "$output" == *"<ESC>]3008;start=claude;event=awaiting_input;pid=4242<ESC>\\"* ]]
  # Oldest first, after the snapshot.
  [[ "$output" == *"READY"*"start=codex"*"start=claude"* ]]
}

@test "notifications are forwarded but not replayed" {
  "$ZMX" run test-agent-notify -d sleep 30
  wait_for_session test-agent-notify

  run "$ZMX" agent notify --session test-agent-notify --title Done --body "Tests pass"
  [ "$status" -eq 0 ]

  run attach_capture test-agent-notify
  [[ "$output" != *"kind=notify"* ]]
}

@test "agent events never reach the session's screen or history" {
  "$ZMX" run test-agent-history -d bash -c 'echo READY; sleep 30'
  wait_for_output test-agent-history "READY"

  "$ZMX" agent notify --session test-agent-history --event busy
  run "$ZMX" history test-agent-history --vt
  [[ "$output" != *"3008"* ]]
}
