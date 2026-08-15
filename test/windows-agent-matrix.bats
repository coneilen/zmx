#!/usr/bin/env bats
# Contract tests for the Windows coding-agent compatibility matrix.

load test_helper

pwsh_matrix() {
  if command -v pwsh >/dev/null 2>&1; then
    printf '%s\n' pwsh
    return 0
  fi
  return 1
}

matrix_script_path() {
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$REPO_DIR/test/windows-agent-matrix.ps1"
  else
    printf '%s\n' "$REPO_DIR/test/windows-agent-matrix.ps1"
  fi
}

@test "Windows agent matrix self-test validates its public contract" {
  local pwsh
  pwsh=$(pwsh_matrix) || skip "PowerShell 7 is not installed"

  run "$pwsh" -NoProfile -File "$(matrix_script_path)" -SelfTest
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema": "zmx/windows-agent-matrix/v1"'
  echo "$output" | grep -q '"status": "pass"'
  echo "$output" | grep -q '"backend_long_turn"'
  echo "$output" | grep -q '"exact_history_markers"'
  echo "$output" | grep -q '"bomless_utf8_input"'
  echo "$output" | grep -q '"sequence_chunk_markers"'
  echo "$output" | grep -q '"output_only_backend_markers"'
  echo "$output" | grep -q '"pending_progress_after_detach"'
  echo "$output" | grep -q '"registration_removal_after_kill"'
  echo "$output" | grep -q '"generic_probe_capabilities"'
  echo "$output" | grep -q '"generic_input_probe_status"'
  echo "$output" | grep -q '"bounded_timeout_cleanup"'
  echo "$output" | grep -q '"runtime_cleanup_failure_propagation"'
  echo "$output" | grep -q '"captured_process_start_failure"'
  echo "$output" | grep -q '"wrong_binary_matrix_json"'
  echo "$output" | grep -q '"matrix_failure_fallback_json"'
}

@test "Windows agent matrix reports every missing backend explicitly" {
  local pwsh
  pwsh=$(pwsh_matrix) || skip "PowerShell 7 is not installed"

  run "$pwsh" -NoProfile -File "$(matrix_script_path)" -DiscoverOnly
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"name": "claude"'
  echo "$output" | grep -q '"name": "copilot"'
  echo "$output" | grep -q '"name": "codex"'
  echo "$output" | grep -q '"install"'
  echo "$output" | grep -q '"version_command"'
}

@test "Windows agent matrix failure injections preserve bounded cleanup contracts" {
  local pwsh
  pwsh=$(pwsh_matrix) || skip "PowerShell 7 is not installed"

  run "$pwsh" -NoProfile -File "$(matrix_script_path)" -FailureInjection
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"mode": "failure-injection"'
  echo "$output" | grep -q '"status": "pass"'
  echo "$output" | grep -q '"observed_status": "fail"'
  echo "$output" | grep -q '"start_failed": true'
  echo "$output" | grep -q '"timed-out process remained alive after bounded post-kill wait"'
  echo "$output" | grep -q '"simulated_exit_code": 1'
}

@test "Windows agent matrix emits failed JSON for a wrong zmx binary" {
  local pwsh wrong_binary
  pwsh=$(pwsh_matrix) || skip "PowerShell 7 is not installed"
  if command -v wslpath >/dev/null 2>&1; then
    wrong_binary=$(wslpath -w "$REPO_DIR/test/fixtures/windows-agent-high-output.ps1")
  else
    wrong_binary="$REPO_DIR/test/fixtures/windows-agent-high-output.ps1"
  fi

  run "$pwsh" -NoProfile -File "$(matrix_script_path)" -ZmxPath "$wrong_binary"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '"status": "fail"'
  echo "$output" | grep -q '"generic_probes"'
  echo "$output" | grep -q '"input_probe"'
  echo "$output" | grep -q '"runtime_cleanup"'
  ! echo "$output" | grep -q 'matrix document was not produced'
}
