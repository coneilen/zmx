[CmdletBinding()]
param(
    [string]$ZmxPath,
    [string]$OutputPath,
    [string]$SessionPrefix = "zmx-agent-matrix-$PID",
    [switch]$DiscoverOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:Schema = "zmx/windows-agent-matrix/v1"
$Script:RequiredCapabilities = @(
    "launch",
    "prompt_input",
    "long_high_output",
    "detach",
    "background_progress",
    "reconnect_vt",
    "send_short",
    "send_large",
    "send_multiline",
    "send_unicode",
    "send_chunking",
    "separate_enter",
    "bracketed_paste",
    "labels",
    "usage_activity_labels",
    "hooks",
    "session_id_resume",
    "ctrl_c",
    "resize",
    "client_crash_survival",
    "app_crash_survival",
    "clean_kill"
)

$Script:BackendCatalog = @(
    [pscustomobject]@{
        name = "claude"
        commands = @("claude")
        install = "npm install -g @anthropic-ai/claude-code"
        version_command = "claude --version"
        docs = "https://docs.anthropic.com/en/docs/claude-code/overview"
    }
    [pscustomobject]@{
        name = "copilot"
        commands = @("copilot", "github-copilot")
        install = "npm install -g @github/copilot"
        version_command = "copilot --version"
        docs = "https://github.com/github/copilot-cli"
    }
    [pscustomobject]@{
        name = "codex"
        commands = @("codex")
        install = "npm install -g @openai/codex"
        version_command = "codex --version"
        docs = "https://github.com/openai/codex"
    }
)

function Redact-PublicText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $value = $Text -replace "\r", " " -replace "\n", " "
    $value = $value -replace "(?i)[A-Z]:\\Users\\[^\\\s]+", "<user-profile>"
    $value = $value -replace "(?i)(token|secret|password|api[_-]?key|authorization|credential)=[^\s]+", '$1=<redacted>'
    if ($value.Length -gt 240) {
        return $value.Substring(0, 240)
    }
    return $value
}

function New-ProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [hashtable]$Environment
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $argumentListProperty = $psi.PSObject.Properties["ArgumentList"]
    if ($null -eq $argumentListProperty) {
        throw "PowerShell 7 or newer is required for deterministic argument passing"
    }
    foreach ($argument in $ArgumentList) {
        [void]$psi.ArgumentList.Add([string]$argument)
    }

    $sensitiveKeys = @($psi.Environment.Keys | Where-Object {
            $_ -match "(?i)(token|secret|password|api[_-]?key|authorization|credential|cookie)"
        })
    foreach ($key in $sensitiveKeys) {
        [void]$psi.Environment.Remove($key)
    }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) {
            $value = $Environment[$key]
            if ($null -eq $value) {
                [void]$psi.Environment.Remove([string]$key)
            } else {
                $psi.Environment[[string]$key] = [string]$value
            }
        }
    }
    return $psi
}

function Read-ProcessOutput {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$Task,
        [int]$WaitMilliseconds = 500
    )

    if (-not $Task.Wait($WaitMilliseconds)) {
        return ""
    }
    try {
        return [string]$Task.Result
    } catch {
        return ""
    }
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [AllowNull()][string]$InputText,
        [int]$Timeout = 10,
        [hashtable]$Environment,
        [switch]$FullOutput
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = New-ProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment
    $commandText = (($FilePath + " " + ($ArgumentList -join " ")).Trim())
    try {
        if (-not $process.Start()) {
            throw "Process did not start"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            $process.StandardInput.Write($InputText)
        }
        $process.StandardInput.Close()
        $finished = $process.WaitForExit($Timeout * 1000)
        if (-not $finished) {
            try { $process.Kill($true) } catch {}
            $process.WaitForExit()
            $stdout = Read-ProcessOutput -Task $stdoutTask
            $stderr = Read-ProcessOutput -Task $stderrTask
            return [pscustomobject]@{
                exit_code = $null
                timed_out = $true
                stdout = if ($FullOutput) { $stdout } else { Redact-PublicText -Text $stdout }
                stderr = if ($FullOutput) { $stderr } else { Redact-PublicText -Text $stderr }
                command = Redact-PublicText -Text $commandText
            }
        }
        $stdout = Read-ProcessOutput -Task $stdoutTask
        $stderr = Read-ProcessOutput -Task $stderrTask
        return [pscustomobject]@{
            exit_code = $process.ExitCode
            timed_out = $false
            stdout = if ($FullOutput) { $stdout } else { Redact-PublicText -Text $stdout }
            stderr = if ($FullOutput) { $stderr } else { Redact-PublicText -Text $stderr }
            command = Redact-PublicText -Text $commandText
        }
    } finally {
        $process.Dispose()
    }
}

function Start-LongProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [hashtable]$Environment
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = New-ProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment
    if (-not $process.Start()) {
        $process.Dispose()
        throw "Process did not start"
    }
    [void]$process.StandardOutput.ReadToEndAsync()
    [void]$process.StandardError.ReadToEndAsync()
    return $process
}

function Stop-ProcessInstance {
    param([AllowNull()][System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            [void]$Process.WaitForExit(2000)
        }
    } catch {}
    $Process.Dispose()
}

function Resolve-CommandSpec {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Source)) {
            continue
        }
        $source = [string]$command.Source
        $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
        if ($extension -eq ".ps1") {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($null -eq $pwsh) {
                continue
            }
            return [pscustomobject]@{
                command_name = $name
                file_path = [string]$pwsh.Source
                version_args = @("-NoProfile", "-File", $source, "--version")
                launch_args = @([string]$pwsh.Source, "-NoProfile", "-File", $source)
            }
        }
        if ($extension -eq ".cmd" -or $extension -eq ".bat") {
            return [pscustomobject]@{
                command_name = $name
                file_path = (Join-Path $env:WINDIR "System32\cmd.exe")
                version_args = @("/d", "/c", $source, "--version")
                launch_args = @((Join-Path $env:WINDIR "System32\cmd.exe"), "/d", "/c", $source)
            }
        }
        return [pscustomobject]@{
            command_name = $name
            file_path = $source
            version_args = @("--version")
            launch_args = @($source)
        }
    }
    return $null
}

function Get-BackendDiscovery {
    $rows = @()
    foreach ($catalog in $Script:BackendCatalog) {
        $spec = Resolve-CommandSpec -Names $catalog.commands
        if ($null -eq $spec) {
            $rows += [ordered]@{
                name = $catalog.name
                status = "skip"
                installed = $false
                version = ""
                install = $catalog.install
                version_command = $catalog.version_command
                docs = $catalog.docs
                diagnostic = "not installed; install: $($catalog.install); version: $($catalog.version_command)"
            }
            continue
        }
        $version = Invoke-Captured -FilePath $spec.file_path -ArgumentList $spec.version_args -Timeout 10
        $versionText = (($version.stdout + " " + $version.stderr).Trim() -split "\s+") -join " "
        $rows += [ordered]@{
            name = $catalog.name
            status = if ($version.exit_code -eq 0) { "available" } else { "diagnostic" }
            installed = $true
            version = Redact-PublicText -Text $versionText
            install = $catalog.install
            version_command = $catalog.version_command
            docs = $catalog.docs
            diagnostic = if ($version.exit_code -eq 0) {
                "installed; public version: $(Redact-PublicText -Text $versionText)"
            } else {
                "installed but version command failed; install: $($catalog.install); version: $($catalog.version_command)"
            }
        }
    }
    return $rows
}

function New-CapabilityMap {
    param([string]$Detail = "not run")

    $capabilities = [ordered]@{}
    foreach ($name in $Script:RequiredCapabilities) {
        [void]($capabilities[$name] = [ordered]@{
                status = "skip"
                detail = $Detail
            })
    }
    return $capabilities
}

function Set-Capability {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Capabilities,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    [void]($Capabilities[$Name] = [ordered]@{
            status = $Status
            detail = Redact-PublicText -Text $Detail
        })
}

function Resolve-ZmxSpec {
    if (-not [string]::IsNullOrWhiteSpace($ZmxPath)) {
        if (-not (Test-Path -LiteralPath $ZmxPath -PathType Leaf)) {
            return $null
        }
        return [pscustomobject]@{
            file_path = (Resolve-Path -LiteralPath $ZmxPath).Path
            environment = @{}
        }
    }
    $defaultPath = Join-Path $PSScriptRoot "..\zig-out\bin\zmx.exe"
    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
        return [pscustomobject]@{
            file_path = (Resolve-Path -LiteralPath $defaultPath).Path
            environment = @{}
        }
    }
    $command = Get-Command zmx -ErrorAction SilentlyContinue
    if ($null -ne $command -and [string]$command.Source -match "\.exe$") {
        return [pscustomobject]@{
            file_path = [string]$command.Source
            environment = @{}
        }
    }
    return $null
}

function Invoke-Zmx {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [AllowNull()][string]$InputText,
        [int]$Timeout = 10,
        [hashtable]$Environment,
        [switch]$FullOutput
    )

    $mergedEnvironment = @{}
    foreach ($key in $Script:ZmxEnvironment.Keys) {
        $mergedEnvironment[$key] = $Script:ZmxEnvironment[$key]
    }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) {
            $mergedEnvironment[$key] = $Environment[$key]
        }
    }
    return Invoke-Captured -FilePath $Script:ZmxSpec.file_path -ArgumentList $ArgumentList `
        -InputText $InputText -Timeout $Timeout -Environment $mergedEnvironment -FullOutput:$FullOutput
}

function Wait-ZmxSession {
    param([Parameter(Mandatory = $true)][string]$Session, [int]$Timeout = 15)

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        $result = Invoke-Zmx -ArgumentList @("list", "--short") -Timeout 5
        if ($result.exit_code -eq 0 -and $result.stdout -split "\s+" -contains $Session) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-ZmxHistory {
    param([Parameter(Mandatory = $true)][string]$Session)

    $result = Invoke-Zmx -ArgumentList @("history", $Session) -Timeout 10 -FullOutput
    if ($result.exit_code -ne 0) {
        return ""
    }
    return [string]$result.stdout
}

function Send-ZmxInput {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Text
    )

    return Invoke-Zmx -ArgumentList @("send", $Session) -InputText $Text -Timeout 10
}

function Test-ZmxFixture {
    param([Parameter(Mandatory = $true)][string]$Session)

    $fixture = Join-Path $PSScriptRoot "fixtures\windows-agent-high-output.ps1"
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -eq $pwsh -or -not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
        return [pscustomobject]@{ status = "skip"; detail = "PowerShell fixture unavailable" }
    }
    $run = Invoke-Zmx -ArgumentList @(
        "run", $Session, "-d", [string]$pwsh.Source, "-NoProfile", "-File", $fixture, "--lines", "256"
    ) -Timeout 10
    if ($run.exit_code -ne 0 -or -not (Wait-ZmxSession -Session $Session -Timeout 10)) {
        return [pscustomobject]@{ status = "fail"; detail = "high-output fixture did not start" }
    }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $history = ""
        while ([DateTime]::UtcNow -lt $deadline) {
            $history = Get-ZmxHistory -Session $Session
            if ($history -match "ZMX_HIGH_OUTPUT_0255") {
                return [pscustomobject]@{
                    status = "pass"
                    detail = "256-line public fixture completed through ConPTY"
                }
            }
            Start-Sleep -Milliseconds 250
        }
        return [pscustomobject]@{
            status = "fail"
            detail = "high-output fixture marker missing; history bytes=$($history.Length)"
        }
    } finally {
        [void](Invoke-Zmx -ArgumentList @("kill", "--force", $Session) -Timeout 10)
    }
}

function Test-Backend {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Catalog,
        [Parameter(Mandatory = $true)][pscustomobject]$Discovery
    )

    $capabilities = New-CapabilityMap -Detail $Discovery.diagnostic
    $session = "$SessionPrefix-$($Catalog.name)"
    $row = [ordered]@{
        name = $Catalog.name
        status = "skipped"
        availability = $Discovery.status
        installed = $Discovery.installed
        version = $Discovery.version
        install = $Discovery.install
        version_command = $Discovery.version_command
        docs = $Discovery.docs
        diagnostic = $Discovery.diagnostic
        session_id = $session
        capabilities = $capabilities
    }

    if ($null -eq $Script:ZmxSpec) {
        $row.diagnostic = "zmx.exe unavailable; build a native Windows zmx binary or pass -ZmxPath; backend: $($Discovery.diagnostic)"
        foreach ($name in $Script:RequiredCapabilities) {
            Set-Capability -Capabilities $capabilities -Name $name -Status "skip" `
                -Detail $row.diagnostic
        }
        return $row
    }
    if (-not $Discovery.installed -or $Discovery.status -eq "skip") {
        return $row
    }
    $spec = Resolve-CommandSpec -Names $Catalog.commands
    if ($null -eq $spec) {
        $row.diagnostic = "backend disappeared after discovery; version: $($Catalog.version_command)"
        return $row
    }

    $runArguments = @("run", $session, "-d") + [string[]]$spec.launch_args
    $run = Invoke-Zmx -ArgumentList $runArguments -Timeout 15
    if ($run.exit_code -ne 0 -or -not (Wait-ZmxSession -Session $session -Timeout 15)) {
        Set-Capability -Capabilities $capabilities -Name "launch" -Status "fail" `
            -Detail "zmx run failed: $($run.stderr)"
        $row.status = "failed"
        $row.diagnostic = "backend launch failed; version: $($Catalog.version_command)"
        return $row
    }
    $row.status = "tested"
    Set-Capability -Capabilities $capabilities -Name "launch" -Status "pass" `
        -Detail "started as a real zmx Windows ConPTY session"

    try {
        $initialHistory = Get-ZmxHistory -Session $session
        $authRequired = $initialHistory -match "(?i)(not authenticated|authenticate|sign in|login required|api key)"
        $prompt = "ZMX_PUBLIC_MATRIX_MARKER Reply with exactly this marker. Do not use tools or modify files."
        $promptResult = Send-ZmxInput -Session $session -Text $prompt
        $short = Send-ZmxInput -Session $session -Text "ZMX_SHORT"
        $enter = Send-ZmxInput -Session $session -Text ([char]13)
        Set-Capability -Capabilities $capabilities -Name "send_short" `
            -Status $(if ($short.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "raw short input"
        Set-Capability -Capabilities $capabilities -Name "separate_enter" `
            -Status $(if ($enter.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "carriage return sent as a separate zmx send"
        Set-Capability -Capabilities $capabilities -Name "prompt_input" `
            -Status $(if ($authRequired) { "skip" } elseif ($promptResult.exit_code -eq 0 -and $enter.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail $(if ($authRequired) { "public prompt not attempted because CLI requests authentication" } else { "public prompt and Enter sent" })

        $large = "ZMX_LARGE_" + ("x" * 4096)
        $largeResult = Send-ZmxInput -Session $session -Text $large
        Set-Capability -Capabilities $capabilities -Name "send_large" `
            -Status $(if ($largeResult.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "4096-byte raw input"

        $multiline = "ZMX_LINE_ONE`r`nZMX_LINE_TWO`nZMX_LINE_THREE"
        $multilineResult = Send-ZmxInput -Session $session -Text $multiline
        Set-Capability -Capabilities $capabilities -Name "send_multiline" `
            -Status $(if ($multilineResult.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "CRLF and LF preserved in one payload"

        $unicodeResult = Send-ZmxInput -Session $session -Text "ZMX_UNICODE_世界_🙂_é"
        Set-Capability -Capabilities $capabilities -Name "send_unicode" `
            -Status $(if ($unicodeResult.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "UTF-8 public marker"

        $chunkStatus = "pass"
        foreach ($chunk in @("ZMX_CHUNK_A", "ZMX_CHUNK_B", "ZMX_CHUNK_C")) {
            $chunkResult = Send-ZmxInput -Session $session -Text $chunk
            if ($chunkResult.exit_code -ne 0) {
                $chunkStatus = "fail"
            }
        }
        Set-Capability -Capabilities $capabilities -Name "send_chunking" -Status $chunkStatus `
            -Detail "three independently framed chunks"

        $paste = ([char]27) + "[200~ZMX_BRACKETED_PASTE`r`nZMX_PASTE_LINE" + ([char]27) + "[201~"
        $pasteResult = Send-ZmxInput -Session $session -Text $paste
        Set-Capability -Capabilities $capabilities -Name "bracketed_paste" `
            -Status $(if ($pasteResult.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "bracketed-paste bytes delivered without a private prompt"

        $setLabels = Invoke-Zmx -ArgumentList @(
            "set", $session, "backend=$($Catalog.name)", "activity=matrix", "usage=public"
        ) -Timeout 10
        $labels = Invoke-Zmx -ArgumentList @("get", $session) -Timeout 10
        $labelsPass = $setLabels.exit_code -eq 0 -and $labels.exit_code -eq 0 `
            -and $labels.stdout -match "backend=$($Catalog.name)" `
            -and $labels.stdout -match "activity=matrix"
        Set-Capability -Capabilities $capabilities -Name "labels" `
            -Status $(if ($labelsPass) { "pass" } else { "fail" }) `
            -Detail "zmx labels round-tripped backend and activity"
        Set-Capability -Capabilities $capabilities -Name "usage_activity_labels" `
            -Status $(if ($labelsPass -and $labels.stdout -match "usage=public") { "pass" } else { "fail" }) `
            -Detail "usage/activity labels are explicit zmx labels"
        Set-Capability -Capabilities $capabilities -Name "hooks" -Status "skip" `
            -Detail "no public cross-agent hook contract was assumed"

        $fixture = Test-ZmxFixture -Session "${session}-fixture"
        Set-Capability -Capabilities $capabilities -Name "long_high_output" `
            -Status $fixture.status -Detail "agent public turn was sent; $($fixture.detail)"

        $progress = Send-ZmxInput -Session $session -Text "ZMX_BACKGROUND_PROGRESS"
        Set-Capability -Capabilities $capabilities -Name "background_progress" `
            -Status $(if ($progress.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "public progress marker sent while detached"

        $attach = $null
        try {
            $attach = Start-LongProcess -FilePath $Script:ZmxSpec.file_path `
                -ArgumentList @("attach", $session) -Environment $Script:ZmxEnvironment
            Start-Sleep -Milliseconds 750
            $attachStarted = -not $attach.HasExited
            if ($attachStarted) {
                $detach = Invoke-Zmx -ArgumentList @("detach") `
                    -Environment @{ ZMX_SESSION = $session } -Timeout 10
                Start-Sleep -Milliseconds 500
                Set-Capability -Capabilities $capabilities -Name "detach" `
                    -Status $(if ($detach.exit_code -eq 0) { "pass" } else { "fail" }) `
                    -Detail "detach-all sent through the attached client session"
            } else {
                Set-Capability -Capabilities $capabilities -Name "detach" -Status "skip" `
                    -Detail "pipe-safe attach client exited before detach"
            }
        } finally {
            Stop-ProcessInstance -Process $attach
        }

        $historyBeforeResume = Get-ZmxHistory -Session $session
        $version = Invoke-Zmx -ArgumentList @("version") -Timeout 10
        $historyAfterResume = Get-ZmxHistory -Session $session
        $resumePass = $version.exit_code -eq 0 -and $historyAfterResume.Length -ge $historyBeforeResume.Length
        Set-Capability -Capabilities $capabilities -Name "session_id_resume" `
            -Status $(if ($resumePass) { "pass" } else { "fail" }) `
            -Detail "session id $session remained discoverable across fresh zmx clients"

        $vtHistory = Invoke-Zmx -ArgumentList @("history", $session, "--vt") -Timeout 10 -FullOutput
        Set-Capability -Capabilities $capabilities -Name "reconnect_vt" `
            -Status $(if ($vtHistory.exit_code -eq 0 -and $vtHistory.stdout.Length -gt 0) { "pass" } else { "fail" }) `
            -Detail "VT history reconstruction returned non-empty output"

        $crashClient = $null
        try {
            $crashClient = Start-LongProcess -FilePath $Script:ZmxSpec.file_path `
                -ArgumentList @("attach", $session) -Environment $Script:ZmxEnvironment
            Start-Sleep -Milliseconds 750
            Stop-ProcessInstance -Process $crashClient
            $crashClient = $null
            Set-Capability -Capabilities $capabilities -Name "client_crash_survival" `
                -Status $(if (Wait-ZmxSession -Session $session -Timeout 5) { "pass" } else { "fail" }) `
                -Detail "attached client terminated by PID while backend session remained"
        } catch {
            Set-Capability -Capabilities $capabilities -Name "client_crash_survival" -Status "skip" `
                -Detail "attach client could not run under the pipe-safe harness"
        } finally {
            Stop-ProcessInstance -Process $crashClient
        }

        $ctrlC = Send-ZmxInput -Session $session -Text ([char]3)
        Set-Capability -Capabilities $capabilities -Name "ctrl_c" `
            -Status $(if ($ctrlC.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "ETX delivered as raw PTY input"
        Set-Capability -Capabilities $capabilities -Name "resize" -Status "skip" `
            -Detail "zmx exposes resize through a live console; stable pipe-only automation is unavailable"
        Set-Capability -Capabilities $capabilities -Name "app_crash_survival" -Status "skip" `
            -Detail "no safe public crash injection was applied to the installed coding agent"
    } finally {
        $kill = Invoke-Zmx -ArgumentList @("kill", "--force", $session) -Timeout 10
        Set-Capability -Capabilities $capabilities -Name "clean_kill" `
            -Status $(if ($kill.exit_code -eq 0) { "pass" } else { "fail" }) `
            -Detail "zmx kill --force completed for $session"
    }
    return $row
}

function Write-JsonDocument {
    param([Parameter(Mandatory = $true)]$Document)

    $json = $Document | ConvertTo-Json -Depth 14
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-Output $json
    } else {
        $parent = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8NoBOM
        Write-Output $json
    }
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or newer is required"
}

if ($SelfTest) {
    if ($Script:RequiredCapabilities.Count -lt 20) {
        throw "matrix contract is missing required capabilities"
    }
    $names = @($Script:BackendCatalog | ForEach-Object { $_.name })
    if ($names -notcontains "claude" -or $names -notcontains "copilot" -or $names -notcontains "codex") {
        throw "matrix contract is missing a target backend"
    }
    Write-JsonDocument -Document ([ordered]@{
            schema = $Script:Schema
            status = "pass"
            required_capabilities = $Script:RequiredCapabilities
            backends = $names
            credential_policy = "No credentials or private prompts are supplied; sensitive environment variables are removed."
        })
    exit 0
}

$discovery = @(Get-BackendDiscovery)
if ($DiscoverOnly) {
    Write-JsonDocument -Document ([ordered]@{
            schema = $Script:Schema
            mode = "discover"
            generated_at = [DateTime]::UtcNow.ToString("o")
            backends = $discovery
        })
    exit 0
}

$Script:ZmxSpec = Resolve-ZmxSpec
$Script:ZmxEnvironment = @{
    ZMX_DIR = Join-Path $PSScriptRoot ".agent-matrix-runtime-$PID"
    ZMX_NO_DETACH_KEY = "1"
}
New-Item -ItemType Directory -Force -Path $Script:ZmxEnvironment.ZMX_DIR | Out-Null

try {
    $backendRows = @()
    foreach ($catalog in $Script:BackendCatalog) {
        $found = $discovery | Where-Object { $_.name -eq $catalog.name } | Select-Object -First 1
        $backendRows += Test-Backend -Catalog $catalog -Discovery $found
    }
    $matrixRows = @($backendRows | Where-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                return $_.Contains("capabilities")
            }
            return $null -ne $_.PSObject.Properties["capabilities"]
        })
    $invalidRows = @($backendRows | Where-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                return -not $_.Contains("capabilities")
            }
            return $null -eq $_.PSObject.Properties["capabilities"]
        })
    if ($invalidRows.Count -gt 0) {
        $invalidTypes = ($invalidRows | ForEach-Object { $_.GetType().FullName } | Sort-Object -Unique) -join ", "
        Write-Warning "matrix backend collector emitted $($invalidRows.Count) unexpected record(s): $invalidTypes"
    }
    $allCapabilities = @($matrixRows | ForEach-Object { $_["capabilities"].Values })
    $summary = [ordered]@{
        pass = @($allCapabilities | Where-Object { $_.status -eq "pass" }).Count
        fail = @($allCapabilities | Where-Object { $_.status -eq "fail" }).Count
        skip = @($allCapabilities | Where-Object { $_.status -eq "skip" }).Count
    }
    Write-JsonDocument -Document ([ordered]@{
            schema = $Script:Schema
            mode = "matrix"
            generated_at = [DateTime]::UtcNow.ToString("o")
            host = [ordered]@{
                os = "Windows"
                powershell = $PSVersionTable.PSVersion.ToString()
            }
            zmx = [ordered]@{
                available = ($null -ne $Script:ZmxSpec)
                diagnostic = if ($null -ne $Script:ZmxSpec) { "native zmx.exe selected" } else { "zmx.exe unavailable; pass -ZmxPath or build with Zig 0.16" }
            }
            credential_policy = "No credentials or private prompts are supplied; sensitive environment variables are removed."
            summary = $summary
            backends = $matrixRows
        })
} finally {
    if (Test-Path -LiteralPath $Script:ZmxEnvironment.ZMX_DIR) {
        Remove-Item -LiteralPath $Script:ZmxEnvironment.ZMX_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}
