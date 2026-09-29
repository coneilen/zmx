#!/usr/bin/env bats
# Pane-geometry tests for zmx.
#
# A client without a terminal (GraphCode runs `zmx attach` as a pipe child)
# cannot measure its own geometry, so it declares it with `--size` and updates
# it with `zmx resize`. Both paths are control-plane only: they must change the
# PTY and the daemon's terminal without typing anything into the session.

load test_helper

# Run `stty size` inside the session and wait for the session's own scrollback
# to report the expected "<rows> <cols>" line.
#
# The probe uses `send`, not `run`: a `run` client measures its own terminal and
# sends a `Resize` frame, claiming vacant leadership and overwriting the
# geometry under test with its fallback (24x120 when it has no tty). `send` is
# pure input, so it observes geometry without changing it.
assert_geometry() {
  local name="$1" expected="$2" i=0
  printf 'stty size\r' | "$ZMX" send "$name" >/dev/null
  while (( i < 50 )); do
    if "$ZMX" history "$name" | grep -qE "(^|[^0-9])${expected}([^0-9]|$)"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Session '$name' never reported geometry '$expected'. History:" >&2
  "$ZMX" history "$name" >&2
  return 1
}

@test "resize: sets session geometry from a non-attached client" {
  "$ZMX" run test-resize -d echo ready
  wait_for_session test-resize

  run "$ZMX" resize test-resize 100x30
  [ "$status" -eq 0 ]

  assert_geometry test-resize "30 100"
}

@test "resize: accepts separate cols and rows arguments" {
  "$ZMX" run test-resize-pair -d echo ready
  wait_for_session test-resize-pair

  run "$ZMX" resize test-resize-pair 90 20
  [ "$status" -eq 0 ]

  assert_geometry test-resize-pair "20 90"
}

@test "resize: applies again so geometry tracks repeated pane changes" {
  "$ZMX" run test-resize-twice -d echo ready
  wait_for_session test-resize-twice

  "$ZMX" resize test-resize-twice 100x30
  assert_geometry test-resize-twice "30 100"

  "$ZMX" resize test-resize-twice 81x21
  assert_geometry test-resize-twice "21 81"
}

@test "resize: types nothing into the session" {
  "$ZMX" run test-resize-quiet -d echo zmx-quiet-marker
  wait_for_session test-resize-quiet
  sleep 0.5
  before="$("$ZMX" history test-resize-quiet)"

  "$ZMX" resize test-resize-quiet 100x30
  sleep 0.5
  after="$("$ZMX" history test-resize-quiet)"

  # A geometry frame is not an input frame: no spec text can reach the shell.
  [[ "$after" != *"100x30"* ]]
  [[ "$after" != *"resize"* ]]
  [[ "$after" == *"zmx-quiet-marker"* ]]
  [[ "$before" == *"zmx-quiet-marker"* ]]
}

@test "resize: rejects degenerate and malformed geometry" {
  "$ZMX" run test-resize-bad -d echo ready
  wait_for_session test-resize-bad

  run "$ZMX" resize test-resize-bad 0x30
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid size"* ]]

  run "$ZMX" resize test-resize-bad 100x0
  [ "$status" -ne 0 ]

  run "$ZMX" resize test-resize-bad nonsense
  [ "$status" -ne 0 ]

  run "$ZMX" resize test-resize-bad
  [ "$status" -ne 0 ]
}

@test "resize: fails for a session that does not exist" {
  run "$ZMX" resize test-resize-missing 100x30
  [ "$status" -ne 0 ]
  assert_output_contains "no such session"
}

@test "resize: reports a missing session before any socket directory exists" {
  # A socket directory is only created once a session is made. Reaching a
  # session through a directory that was never created is still just a missing
  # session, and must say so rather than surfacing a raw filesystem error.
  run env ZMX_DIR="$BATS_TEST_TMPDIR/never-created" "$ZMX" resize test-resize-missing 100x30
  [ "$status" -ne 0 ]
  assert_output_contains "no such session"
}

@test "resize: records which check produced the missing-session verdict" {
  # An absent socket and a socket nobody is listening on are reported to the
  # user identically, on purpose. That makes the two indistinguishable once
  # they agree, so the verdict names its own origin in the log. Asserting it
  # here keeps a passing run informative instead of merely silent, and tells
  # us which path a given platform actually took.
  run "$ZMX" resize test-resize-missing 100x30
  [ "$status" -ne 0 ]
  assert_output_contains "no such session"

  local log="$ZMX_DIR/logs/zmx.log"
  [ -f "$log" ]
  grep -q "no such session verdict path=precheck" "$log"
}

@test "attach --size: declares geometry for a client with no terminal" {
  # A pipe for stdin and stdout, exactly like the GraphCode terminal surface:
  # the client has no tty to measure and stays attached while the pane lives.
  fifo="$BATS_TEST_TMPDIR/attach-stdin"
  mkfifo "$fifo"
  sleep 60 >"$fifo" &
  holder_pid=$!

  "$ZMX" attach test-attach-size --size 100x30 <"$fifo" >/dev/null 2>&1 &
  attach_pid=$!
  wait_for_session test-attach-size

  assert_geometry test-attach-size "30 100"

  # The control plane still owns geometry while that client is attached.
  "$ZMX" resize test-attach-size 81x21
  assert_geometry test-attach-size "21 81"

  "$ZMX" kill --force test-attach-size || true
  kill "$holder_pid" 2>/dev/null || true
  wait "$attach_pid" 2>/dev/null || true
}

@test "attach --size: declaration survives a client whose stdin is already EOF" {
  # A one-shot client may exit immediately; its declared geometry must still
  # have reached the daemon rather than being lost in an unflushed buffer.
  "$ZMX" attach test-attach-eof --size 100x30 </dev/null >/dev/null 2>&1 || true
  wait_for_session test-attach-eof

  assert_geometry test-attach-eof "30 100"
}

@test "attach --size: rejects a malformed spec without creating a session" {
  run "$ZMX" attach test-attach-bad --size 0x30
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid size"* ]]

  run "$ZMX" list --short
  [[ "$output" != *"test-attach-bad"* ]]
}
