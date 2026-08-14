# Windows coding-agent compatibility matrix

`test/windows-agent-matrix.ps1` is a reproducible, credential-free probe for
coding-agent CLIs running in native Windows zmx sessions. It discovers Claude
Code, GitHub Copilot CLI, and Codex, records public version/install
diagnostics, and emits JSON using schema `zmx/windows-agent-matrix/v1`.

## Run

Build a native Windows binary with Zig 0.16, then run:

```powershell
pwsh -NoProfile -File .\test\windows-agent-matrix.ps1 `
  -ZmxPath .\zig-out\bin\zmx.exe `
  -OutputPath .\agent-matrix.json
```

Discovery does not require zmx:

```powershell
pwsh -NoProfile -File .\test\windows-agent-matrix.ps1 -DiscoverOnly
```

The script removes environment variables whose names expose tokens, secrets,
passwords, API keys, authorization, credentials, or cookies. Prompts are
public deterministic markers and explicitly prohibit tools and file changes.
No credentials or private prompts are supplied.

## Coverage

Available backends are launched with `zmx run` and exercised through the real
Windows ConPTY path. The matrix covers prompt/Enter framing, short/large/
multiline/Unicode/chunked input, bracketed paste bytes, deterministic
high-output, labels, detach/background progress, VT history reconstruction,
fresh-client session resume, Ctrl+C, client termination, and clean kill.

`resize`, agent-specific hooks, and app-crash injection are explicit `skip`
records when the pipe-safe PowerShell runner cannot automate them safely.
Missing or unauthenticated backends are also explicit skips with public
install/version diagnostics; they are never treated as passing.

## TDD evidence

The BATS contract in `test/windows-agent-matrix.bats` runs the PowerShell
`-SelfTest` and `-DiscoverOnly` modes. The expected workflow is:

1. **RED** — contract tests fail when the matrix script is absent.
2. **GREEN** — self-test, discovery, and the native matrix run produce the
   documented schema.
3. **REGRESSION** — run the native Windows matrix plus the existing Windows,
   WSL, release, and BATS suites; a missing backend remains a visible skip.
