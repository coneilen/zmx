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
