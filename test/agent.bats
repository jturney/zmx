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

# ============================================================================
# Asks
# ============================================================================

# start_ask <session> [extra args...]: runs `zmx agent ask` in the background
# with a small permission request, its stdout in $BATS_TEST_TMPDIR/ask.out.
start_ask() {
  local session="$1"; shift
  echo '{"title":"Bash","summary":"make clean","detail":{"command":"make clean"}}' |
    "$ZMX" agent ask --session "$session" --type permission "$@" > "$BATS_TEST_TMPDIR/ask.out" &
  ASK_PID=$!
}

# wait_for_pending <session>: waits until the session shows a pending ask and
# prints its rid and nonce (from the event stream, which carries the nonce).
wait_for_pending() {
  local session="$1" i=0
  while (( i < 50 )); do
    if "$ZMX" agent status --session "$session" --json | grep -q '"pending":\[{'; then
      timeout 1 "$ZMX" agent events --session "$session" 2>/dev/null |
        python3 -c 'import json,sys
for line in sys.stdin:
    e = json.loads(line)
    if e.get("type") == "ask":
        print(e["rid"], e["nonce"]); break'
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for a pending ask in '$session'" >&2
  return 1
}

@test "ask: an out-of-band reply answers it" {
  "$ZMX" run test-ask -d sleep 30
  wait_for_session test-ask

  start_ask test-ask
  read -r rid nonce < <(wait_for_pending test-ask)
  [ -n "$nonce" ]

  run "$ZMX" agent reply --session test-ask "$rid" "$nonce" --allow
  [ "$status" -eq 0 ]
  wait "$ASK_PID"
  [ "$(cat "$BATS_TEST_TMPDIR/ask.out")" = '{"behavior":"allow"}' ]

  # Gone once answered; a second answer is refused.
  run "$ZMX" agent status --session test-ask --json
  [[ "$output" == *'"pending":[]'* ]]
  run "$ZMX" agent reply --session test-ask "$rid" "$nonce" --deny
  [ "$status" -eq 2 ]
}

@test "ask: a wrong nonce is refused and leaves it pending" {
  "$ZMX" run test-ask-nonce -d sleep 30
  wait_for_session test-ask-nonce

  start_ask test-ask-nonce
  read -r rid nonce < <(wait_for_pending test-ask-nonce)

  run "$ZMX" agent reply --session test-ask-nonce "$rid" 00000000000000000000000000000000 --allow
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown rid"* ]]
  run "$ZMX" agent status --session test-ask-nonce --json
  [[ "$output" == *'"pending":[{"rid":'"$rid"* ]]

  "$ZMX" agent reply --session test-ask-nonce "$rid" "$nonce" --json '{"behavior":"deny","message":"no"}'
  wait "$ASK_PID"
  [ "$(cat "$BATS_TEST_TMPDIR/ask.out")" = '{"behavior":"deny","message":"no"}' ]
}

@test "ask: a timeout prints nothing" {
  "$ZMX" run test-ask-timeout -d sleep 30
  wait_for_session test-ask-timeout

  start_ask test-ask-timeout --timeout 1
  wait "$ASK_PID"
  [ ! -s "$BATS_TEST_TMPDIR/ask.out" ]
  run "$ZMX" agent status --session test-ask-timeout --json
  [[ "$output" == *'"pending":[]'* ]]
}

@test "ask: the agent going idle cancels it" {
  "$ZMX" run test-ask-idle -d sleep 30
  wait_for_session test-ask-idle

  start_ask test-ask-idle
  wait_for_pending test-ask-idle > /dev/null
  "$ZMX" agent notify --session test-ask-idle --event idle
  wait "$ASK_PID"
  [ ! -s "$BATS_TEST_TMPDIR/ask.out" ]
}

@test "ask: killing the asker withdraws it" {
  "$ZMX" run test-ask-kill -d sleep 30
  wait_for_session test-ask-kill

  start_ask test-ask-kill
  wait_for_pending test-ask-kill > /dev/null
  timeout 3 "$ZMX" agent events --session test-ask-kill > "$BATS_TEST_TMPDIR/events.out" &
  sleep 0.3
  kill "$ASK_PID"
  wait "$ASK_PID" 2>/dev/null || true
  for _ in $(seq 30); do grep -q '"why":"cancelled"' "$BATS_TEST_TMPDIR/events.out" && break; sleep 0.1; done
  grep -q '"type":"resolved","rid":1,"why":"cancelled"' "$BATS_TEST_TMPDIR/events.out"
}

@test "ask: outside a session it returns at once with nothing" {
  run bash -c 'echo "{}" | env -u ZMX_SESSION "$0" agent ask --type permission' "$ZMX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ask: a terminal answers it in-band, and the reply never reaches the PTY" {
  # `cat` echoes whatever reaches the PTY, so a leaked reply would show up in
  # the session's history.
  "$ZMX" run test-ask-tty -d bash -c 'echo READY; exec cat'
  wait_for_output test-ask-tty "READY"

  # Ask before the terminal attaches, so it learns of the ask from the replay.
  start_ask test-ask-tty
  wait_for_pending test-ask-tty > /dev/null

  python3 - "$ZMX" test-ask-tty 3>&- <<'PY'
import base64, json, os, pty, re, select, sys, time
zmx, session = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv(zmx, [zmx, "attach", session])
out, deadline, m = b"", time.time() + 10, None
while time.time() < deadline and not m:
    if select.select([fd], [], [], 0.1)[0]:
        out += os.read(fd, 65536)
    m = re.search(rb"kind=ask;rid=(\d+);nonce=([0-9a-f]{32});sess=([A-Za-z0-9+/=]+);", out)
if not m:
    sys.exit("the attached terminal never saw the ask")
decision = base64.b64encode(json.dumps({"behavior": "allow"}).encode()).decode()
reply = "\x1b_zmx-reply;sess=%s;rid=%s;nonce=%s;d=%s\x1b\\" % (m[3].decode(), m[1].decode(), m[2].decode(), decision)
# Split across two writes, as a terminal's paste can be.
os.write(fd, reply[:9].encode()); time.sleep(0.05); os.write(fd, reply[9:].encode())
time.sleep(1)
os.write(fd, b"\x1c")  # ctrl+\ detaches
time.sleep(0.3)
os.kill(pid, 9)
PY

  wait "$ASK_PID"
  [ "$(cat "$BATS_TEST_TMPDIR/ask.out")" = '{"behavior":"allow"}' ]
  run "$ZMX" history test-ask-tty
  [[ "$output" != *"zmx-reply"* ]]
}
