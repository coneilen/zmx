# test_helper.bash — shared setup/teardown for zmx BATS tests

REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  # Build once per test suite (skips if already built)
  if [[ ! -x "$REPO_DIR/zig-out/bin/zmx" ]]; then
    cd "$REPO_DIR" && zig build
  fi
  ZMX="$REPO_DIR/zig-out/bin/zmx"

  # Isolate socket dir so tests don't interfere with real sessions or each other
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx-sockets"
  mkdir -p "$ZMX_DIR"
}

teardown() {
  # Kill any sessions created during this test
  if [[ -d "$ZMX_DIR" ]]; then
    local sessions
    sessions=$("$ZMX" list --short 2>/dev/null) || true
    if [[ -n "$sessions" ]]; then
      echo "$sessions" | xargs "$ZMX" kill --force 2>/dev/null || true
    fi
  fi
}

# Helper: wait for a session to appear in list (up to N seconds)
wait_for_session() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" list --short 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name'" >&2
  return 1
}

# Helper: wait for a marker to appear in a session's history (up to N seconds).
# Use this instead of a fixed sleep whenever a test needs the daemon to have
# processed and buffered PTY output before it checks/sends more.
wait_for_output() {
  local name="$1" marker="$2" timeout="${3:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" history "$name" 2>/dev/null | grep -qF "$marker"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for output '$marker' in session '$name'" >&2
  return 1
}

# Helper: wait for a session's cwd to match expected substring (up to N seconds).
wait_for_cwd() {
  local name="$1" pattern="$2" timeout="${3:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" list 2>/dev/null | grep -F "name=$name" | grep -qF "$pattern"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for cwd '$pattern' in session '$name'" >&2
  return 1
}

# Helper: assert run output contains a substring, reporting what was actually
# produced when it does not. A bare [[ $output == *...* ]] reports only the
# failing line, which makes a platform-specific difference impossible to
# diagnose from CI logs alone.
assert_output_contains() {
  local needle="$1"
  if [[ "$output" != *"$needle"* ]]; then
    {
      echo "expected output to contain: $needle"
      echo "actual status: $status"
      echo "actual output: [$output]"
    } >&2
    return 1
  fi
}

# Helper: the longest session name that fits the current socket directory.
#
# The budget is sockaddr_un.sun_path minus the socket directory, and sun_path
# is 108 bytes on Linux but 104 on macOS, where TMPDIR is also far longer
# (/var/folders/...). A name that fits a Linux runner can therefore overflow a
# macOS one and fail as NameTooLong long before reaching the behaviour a test
# means to exercise. Ask the binary rather than hardcoding either platform.
session_name_budget() {
  local probe
  probe="$("$ZMX" resize "$(printf 'n%.0s' {1..80})" 1x1 2>&1 || true)"
  sed -n 's/.*max \([0-9][0-9]*\) .*/\1/p' <<<"$probe"
}

# Helper: fail with an explanation if a fixture name cannot fit the budget,
# so an overflow is reported as the fixture defect it is instead of surfacing
# as an unrelated assertion failure.
assert_name_fits() {
  local name="$1" budget
  budget="$(session_name_budget)"
  if [[ -n "$budget" ]] && (( ${#name} > budget )); then
    echo "fixture session name '$name' is ${#name} bytes, over the ${budget}-byte budget for $ZMX_DIR" >&2
    return 1
  fi
}
