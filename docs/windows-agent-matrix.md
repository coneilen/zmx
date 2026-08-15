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
Windows ConPTY path. A separate public echo probe makes every raw-input pass
observable with exact history markers, including short/large/multiline/
Unicode/chunked input, separate Enter, and bracketed-paste payload handling.
The Unicode probe verifies BOM-less UTF-8 using BMP characters that Windows
ConPTY can round-trip exactly; the bracketed-paste probe verifies the payload
after ConPTY consumes its framing controls. The matrix
also covers backend reply markers, deterministic generic zmx/ConPTY
high-output sequence/chunk markers, labels, detach/background progress, VT
history reconstruction, fresh-client session resume, Ctrl+C, client
termination, and clean kill. The high-output result is labeled generic unless
the active backend itself produced the markers; it never counts fixture output
as a backend turn. Generic ConPTY input/high-output capabilities are emitted
under top-level `generic_probes`, never copied into an authentication-skipped
backend row.

Authentication is checked from initial output before any backend input is
sent. Authentication-required backends keep agent-dependent capabilities as
explicit skips; generic zmx/ConPTY probe results are reported separately.
Backend response envelopes are assembled from separated prompt fragments, so
the exact expected marker is output-only and cannot be satisfied by TUI echo.
Background progress detaches an attached client while a deterministic delayed
operation is pending, then polls for the marker produced after detach.
Process input/output uses BOM-less UTF-8 and exact Unicode/base64 markers, and
cleanup force-stops any remaining captured process before polling registration
removal and daemon-process absence after every launch attempt. Stale
registrations make the matrix fail; cleanup failures propagate through generic
and backend probe results.

`resize`, agent-specific hooks, and app-crash injection are explicit `skip`
records when the pipe-safe PowerShell runner cannot automate them safely.
Missing or unauthenticated backends are also explicit skips with public
install/version diagnostics; they are never treated as passing.

## TDD evidence

The BATS contract in `test/windows-agent-matrix.bats` runs the PowerShell
`-SelfTest` and `-DiscoverOnly` modes. The expected workflow is:

1. **RED** — contract tests fail when the matrix script is absent or exact
   marker/cleanup assertions are removed.
2. **GREEN** — self-test, discovery, and the native matrix run produce the
   documented schema with bounded observable probes.
3. **REGRESSION** — run the native Windows matrix plus the existing Windows,
   WSL, release, and BATS suites; a missing or unauthenticated backend remains
   a visible skip.
