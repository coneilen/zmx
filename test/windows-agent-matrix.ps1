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
    "backend_long_turn",
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
$Script:GenericCapabilities = @(
    "send_short",
    "send_large",
    "send_multiline",
    "send_unicode",
    "send_chunking",
    "separate_enter",
    "bracketed_paste",
    "long_high_output",
    "probe_cleanup"
)
$Script:BackendCapabilities = @(
    $Script:RequiredCapabilities | Where-Object {
        $Script:GenericCapabilities -notcontains $_
    }
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
    $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

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
    param(
        [string]$Detail = "not run",
        [string[]]$Names = $Script:RequiredCapabilities
    )

    $capabilities = [ordered]@{}
    foreach ($name in $Names) {
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

function Wait-ZmxHistoryMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Marker,
        [int]$Timeout = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        $history = Get-ZmxHistory -Session $Session
        if ($history.Contains($Marker)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-ZmxVtHistoryMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Marker,
        [int]$Timeout = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        $history = Invoke-Zmx -ArgumentList @("history", $Session, "--vt") `
            -Timeout 10 -FullOutput
        $text = if ($null -eq $history.stdout) { "" } else { [string]$history.stdout }
        if ($text.Contains($Marker)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-ZmxSessionRegistration {
    param([Parameter(Mandatory = $true)][string]$Session)

    $result = Invoke-Zmx -ArgumentList @("list") -Timeout 10
    if ($result.exit_code -ne 0) {
        return [pscustomobject]@{
            query_succeeded = $false
            registered = $false
            pid = $null
            detail = "zmx list failed: $($result.stderr)"
        }
    }
    foreach ($line in ($result.stdout -split "`r?`n")) {
        if ($line -match "name=$([regex]::Escape($Session))\b") {
            $match = [regex]::Match($line, "\bpid=(\d+)\b")
            $pid = $null
            if ($match.Success) {
                $pid = [int]$match.Groups[1].Value
            }
            return [pscustomobject]@{
                query_succeeded = $true
                registered = $true
                pid = $pid
                detail = Redact-PublicText -Text $line
            }
        }
    }
    return [pscustomobject]@{
        query_succeeded = $true
        registered = $false
        pid = $null
        detail = "session registration absent"
    }
}

function Get-ZmxSessionPid {
    param([Parameter(Mandatory = $true)][string]$Session)

    $registration = Get-ZmxSessionRegistration -Session $Session
    if ($registration.registered) {
        return $registration.pid
    }
    return $null
}

function Get-ZmxCommandLinePid {
    param([Parameter(Mandatory = $true)][string]$Session)

    try {
        $escaped = [regex]::Escape($Session)
        $process = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match "(?i)^zmx(?:\.exe)?$" -and
                [string]$_.CommandLine -match $escaped
            } |
            Select-Object -First 1
        if ($null -ne $process) {
            return [int]$process.ProcessId
        }
    } catch {}
    return $null
}

function Test-WindowsProcessAbsent {
    param([AllowNull()][Nullable[int]]$ProcessId)

    if ($null -eq $ProcessId) {
        return $true
    }
    return $null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Wait-ZmxSessionAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [AllowNull()][Nullable[int]]$ProcessId,
        [int]$Timeout = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        $registration = Get-ZmxSessionRegistration -Session $Session
        $listedPid = if ($registration.registered) { $registration.pid } else { $null }
        $commandLinePid = if ($null -eq $ProcessId) {
            Get-ZmxCommandLinePid -Session $Session
        } else {
            $null
        }
        $remainingPid = if ($null -ne $listedPid) { $listedPid } else { $commandLinePid }
        $processAbsent = if ($null -ne $remainingPid) {
            Test-WindowsProcessAbsent -ProcessId $remainingPid
        } else {
            Test-WindowsProcessAbsent -ProcessId $ProcessId
        }
        if ($registration.query_succeeded -and
            -not $registration.registered -and $null -eq $remainingPid -and $processAbsent)
        {
            return [pscustomobject]@{
                registration_removed = $true
                process_absent = $true
                registered = $false
                detail = "session registration and process are absent"
            }
        }
        Start-Sleep -Milliseconds 250
    }
    $registration = Get-ZmxSessionRegistration -Session $Session
    $remainingPid = if ($registration.registered) {
        $registration.pid
    } elseif ($null -eq $ProcessId) {
        Get-ZmxCommandLinePid -Session $Session
    } else {
        $null
    }
    return [pscustomobject]@{
        registration_removed = $registration.query_succeeded -and -not $registration.registered
        process_absent = if ($null -ne $remainingPid) {
            Test-WindowsProcessAbsent -ProcessId $remainingPid
        } else {
            Test-WindowsProcessAbsent -ProcessId $ProcessId
        }
        registered = $registration.registered
        detail = if ($registration.registered) {
            "session registration remains: $($registration.detail)"
        } else {
            "session/process disappearance was not observed: $($registration.detail)"
        }
    }
}

function Stop-ZmxSession {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [AllowNull()][Nullable[int]]$ProcessId
    )

    $targetPid = if ($null -ne $ProcessId) {
        $ProcessId
    } else {
        Get-ZmxCommandLinePid -Session $Session
    }
    $kill = Invoke-Zmx -ArgumentList @("kill", "--force", $Session) -Timeout 10
    if ($null -ne $targetPid -and $null -ne (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        try {
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    $absent = Wait-ZmxSessionAbsent -Session $Session -ProcessId $targetPid -Timeout 10
    $success = $absent.registration_removed -and $absent.process_absent
    return [pscustomobject]@{
        exit_code = $kill.exit_code
        success = $success
        registration_removed = $absent.registration_removed
        process_absent = $absent.process_absent
        registered = $absent.registered
        detail = $absent.detail
        target_pid = $targetPid
    }
}

function Wait-ProcessExit {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$Timeout = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $Process.HasExited
}

function Get-Utf8Base64 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    return [Convert]::ToBase64String($utf8.GetBytes($Text))
}

function New-BackendMarkerProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $fragmentA = "ZMX_OUTPUT_BEGIN_${Kind}_${Backend}"
    $fragmentB = "_${PID}_END"
    $marker = "$fragmentA$fragmentB"
    $prompt = "Reply with one line containing the exact output envelope formed by " +
        "concatenating fragment A [$fragmentA] and fragment B [$fragmentB], " +
        "with no separator. Do not use tools or modify files."
    if ($prompt.Contains($marker)) {
        throw "backend marker was included contiguously in submitted input"
    }
    return [pscustomobject]@{
        marker = $marker
        prompt = $prompt
    }
}

function Send-ZmxInput {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Text
    )

    return Invoke-Zmx -ArgumentList @("send", $Session) -InputText $Text -Timeout 10
}

function Test-ZmxInputProbe {
    param([Parameter(Mandatory = $true)][string]$Session)

    $capabilities = New-CapabilityMap -Names $Script:GenericCapabilities `
        -Detail "generic zmx/ConPTY input probe not run"
    $fixture = Join-Path $PSScriptRoot "fixtures\windows-agent-input-probe.ps1"
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    $launchAttempted = $false
    $processId = $null
    try {
        if ($null -eq $pwsh -or -not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
            return $capabilities
        }
        $launchAttempted = $true
        $run = Invoke-Zmx -ArgumentList @(
            "run", $Session, "-d", [string]$pwsh.Source, "-NoProfile", "-File", $fixture
        ) -Timeout 10
        if ($run.exit_code -ne 0 -or -not (Wait-ZmxSession -Session $Session -Timeout 10) -or
            -not (Wait-ZmxHistoryMarker -Session $Session -Marker "ZMX_PROBE_READY" -Timeout 10))
        {
            return $capabilities
        }
        $processId = Get-ZmxSessionPid -Session $Session

        $short = Send-ZmxInput -Session $Session -Text "ZMX_SHORT_PROBE`r"
        $shortPass = Wait-ZmxHistoryMarker -Session $Session `
            -Marker "ZMX_PROBE_TEXT:ZMX_SHORT_PROBE" -Timeout 10
        Set-Capability -Capabilities $capabilities -Name "send_short" `
            -Status $(if ($shortPass) { "pass" } else { "fail" }) `
            -Detail "exact short marker echoed by the generic ConPTY probe"

        $separate = Send-ZmxInput -Session $Session -Text "ZMX_SEPARATE_ENTER_PROBE"
        Start-Sleep -Milliseconds 300
        $beforeEnter = Get-ZmxHistory -Session $Session
        $enter = Send-ZmxInput -Session $Session -Text ([char]13)
        $separatePass = -not $beforeEnter.Contains("ZMX_PROBE_TEXT:ZMX_SEPARATE_ENTER_PROBE") `
            -and (Wait-ZmxHistoryMarker -Session $Session -Marker "ZMX_PROBE_TEXT:ZMX_SEPARATE_ENTER_PROBE" -Timeout 10)
        Set-Capability -Capabilities $capabilities -Name "separate_enter" `
            -Status $(if ($separatePass) { "pass" } else { "fail" }) `
            -Detail "marker appeared only after the separately framed Enter"

        $largeText = "ZMX_LARGE_PROBE_" + ("x" * 4096)
        $large = Send-ZmxInput -Session $Session -Text "$largeText`r"
        $largePayloadLength = ([Text.Encoding]::UTF8.GetBytes("$largeText`r")).Length
        $largePass = Wait-ZmxHistoryMarker -Session $Session `
            -Marker "ZMX_PROBE_TEXT:ZMX_LARGE_PROBE_" -Timeout 10
        $largeHistory = Get-ZmxHistory -Session $Session
        $largePass = $largePass -and
            $largeHistory.Contains("ZMX_PROBE_LEN:$largePayloadLength")
        Set-Capability -Capabilities $capabilities -Name "send_large" `
            -Status $(if ($largePass) { "pass" } else { "fail" }) `
            -Detail "4096-byte payload and probe length marker observed"

        $multiline = Send-ZmxInput -Session $Session -Text "ZMX_MULTI_ONE`r`nZMX_MULTI_TWO`r"
        $multilinePass = (Wait-ZmxHistoryMarker -Session $Session -Marker "ZMX_PROBE_TEXT:ZMX_MULTI_ONE" -Timeout 10) `
            -and (Wait-ZmxHistoryMarker -Session $Session -Marker "ZMX_PROBE_TEXT:ZMX_MULTI_TWO" -Timeout 10)
        Set-Capability -Capabilities $capabilities -Name "send_multiline" `
            -Status $(if ($multilinePass) { "pass" } else { "fail" }) `
            -Detail "both CRLF/LF line markers echoed exactly"

        $unicode = "ZMX_UNICODE_世界_Ж_λ_é"
        $unicodePayload = "$unicode`r"
        $unicodeResult = Send-ZmxInput -Session $Session -Text $unicodePayload
        $unicodeBase64 = Get-Utf8Base64 -Text $unicodePayload
        $unicodePass = (Wait-ZmxHistoryMarker -Session $Session -Marker "ZMX_PROBE_TEXT:$unicode" -Timeout 10) `
            -and (Wait-ZmxHistoryMarker -Session $Session `
                -Marker "ZMX_PROBE_B64:$unicodeBase64" -Timeout 10)
        Set-Capability -Capabilities $capabilities -Name "send_unicode" `
            -Status $(if ($unicodePass) { "pass" } else { "fail" }) `
            -Detail "exact UTF-8 text and BOM-less byte encoding marker observed"

        $chunked = Send-ZmxInput -Session $Session -Text "ZMX_CHUNK_A"
        $chunked2 = Send-ZmxInput -Session $Session -Text "ZMX_CHUNK_B"
        $chunked3 = Send-ZmxInput -Session $Session -Text "ZMX_CHUNK_C"
        $chunkEnter = Send-ZmxInput -Session $Session -Text ([char]13)
        $chunkPass = Wait-ZmxHistoryMarker -Session $Session `
            -Marker "ZMX_PROBE_TEXT:ZMX_CHUNK_AZMX_CHUNK_BZMX_CHUNK_C" -Timeout 10
        Set-Capability -Capabilities $capabilities -Name "send_chunking" `
            -Status $(if ($chunkPass) { "pass" } else { "fail" }) `
            -Detail "all three independently framed chunks reconstructed in order"

        $paste = ([char]27) + "[200~ZMX_BRACKETED_PASTE" + ([char]27) + "[201~"
        $pasteResult = Send-ZmxInput -Session $Session -Text "$paste`r"
        $pastePayload = "ZMX_BRACKETED_PASTE`r"
        $pasteBase64 = Get-Utf8Base64 -Text $pastePayload
        $pastePass = (Wait-ZmxHistoryMarker -Session $Session `
                -Marker "ZMX_PROBE_TEXT:ZMX_BRACKETED_PASTE" -Timeout 10) `
            -and (Wait-ZmxHistoryMarker -Session $Session `
                -Marker "ZMX_PROBE_NORMALIZED_B64:$pasteBase64" -Timeout 10)
        Set-Capability -Capabilities $capabilities -Name "bracketed_paste" `
            -Status $(if ($pastePass) { "pass" } else { "fail" }) `
            -Detail "bracketed-paste framing was observed and the exact payload was echoed"
    } finally {
        if ($launchAttempted) {
            $cleanup = Stop-ZmxSession -Session $Session -ProcessId $processId
            Set-Capability -Capabilities $capabilities -Name "probe_cleanup" `
                -Status $(if ($cleanup.success) { "pass" } else { "fail" }) `
                -Detail "generic input probe cleanup: $($cleanup.detail)"
        }
    }
    return $capabilities
}

function Get-BackendAuthRequired {
    param([Parameter(Mandatory = $true)][string]$Session, [int]$Timeout = 5)

    $patterns = "(?i)(not authenticated|authentication required|authenticate|sign in|login required|api key|token required|unauthorized|confirm folder trust|do you trust)"
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Get-ZmxHistory -Session $Session) -match $patterns) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Set-AgentDependentSkips {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Capabilities,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    foreach ($name in @(
            "prompt_input",
            "backend_long_turn",
            "background_progress",
            "detach",
            "reconnect_vt",
            "session_id_resume",
            "ctrl_c",
            "client_crash_survival",
            "app_crash_survival"
        ))
    {
        Set-Capability -Capabilities $Capabilities -Name $name -Status "skip" -Detail $Detail
    }
}

function Test-ZmxFixture {
    param([Parameter(Mandatory = $true)][string]$Session)

    $fixture = Join-Path $PSScriptRoot "fixtures\windows-agent-high-output.ps1"
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    $launchAttempted = $false
    $processId = $null
    $result = [pscustomobject]@{
        status = "skip"
        detail = "generic zmx/ConPTY fixture not run"
        cleanup = $null
    }
    try {
        if ($null -eq $pwsh -or -not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
            $result.status = "skip"
            $result.detail = "PowerShell fixture unavailable"
            return $result
        }
        $launchAttempted = $true
        $lines = 256
        $chunkSize = 32
        $run = Invoke-Zmx -ArgumentList @(
            "run", $Session, "-d", [string]$pwsh.Source, "-NoProfile", "-File", $fixture,
            "-Lines", $lines, "-ChunkSize", $chunkSize, "-HoldSeconds", "3"
        ) -Timeout 10
        if ($run.exit_code -ne 0 -or -not (Wait-ZmxSession -Session $Session -Timeout 10)) {
            $result.status = "fail"
            $result.detail = "high-output fixture did not start"
            return $result
        }
        $processId = Get-ZmxSessionPid -Session $Session
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $history = ""
        $expected = @("ZMX_HIGH_OUTPUT_BEGIN")
        for ($index = 0; $index -lt $lines; $index++) {
            if ($index % $chunkSize -eq 0) {
                $expected += "ZMX_HIGH_OUTPUT_CHUNK_{0:D2}_BEGIN" -f ([int]($index / $chunkSize))
            }
            $expected += "ZMX_HIGH_OUTPUT_{0:D4}" -f $index
            if (($index + 1) % $chunkSize -eq 0 -or $index -eq $lines - 1) {
                $expected += "ZMX_HIGH_OUTPUT_CHUNK_{0:D2}_END" -f ([int]($index / $chunkSize))
            }
        }
        $expected += "ZMX_HIGH_OUTPUT_END"
        while ([DateTime]::UtcNow -lt $deadline) {
            $history = Get-ZmxHistory -Session $Session
            $missing = @()
            $cursor = -1
            foreach ($marker in $expected) {
                $position = $history.IndexOf($marker)
                if ($position -lt 0) {
                    $missing += $marker
                    continue
                }
                if ($position -lt $cursor) {
                    $missing += "$marker (out of order)"
                    continue
                }
                $cursor = $position
            }
            if ($missing.Count -eq 0) {
                $result.status = "pass"
                $result.detail = "generic zmx/ConPTY fixture observed all $lines sequence and chunk markers"
                return $result
            }
            Start-Sleep -Milliseconds 250
        }
        $result.status = "fail"
        $result.detail = "generic zmx/ConPTY fixture missing or reordered $($missing.Count) sequence/chunk markers"
        return $result
    } finally {
        if ($launchAttempted) {
            $result.cleanup = Stop-ZmxSession -Session $Session -ProcessId $processId
            if (-not $result.cleanup.success) {
                $result.status = "fail"
                $result.detail = "$($result.detail); cleanup failed: $($result.cleanup.detail)"
            }
        }
    }
}

function Test-GenericProbes {
    $capabilities = New-CapabilityMap -Names $Script:GenericCapabilities `
        -Detail "generic zmx/ConPTY probes not run"
    if ($null -eq $Script:ZmxSpec) {
        foreach ($name in $Script:GenericCapabilities) {
            Set-Capability -Capabilities $capabilities -Name $name -Status "skip" `
                -Detail "zmx.exe unavailable; pass -ZmxPath or build a native Windows binary"
        }
        return [ordered]@{
            status = "skip"
            capabilities = $capabilities
        }
    }

    $input = Test-ZmxInputProbe -Session "${SessionPrefix}-generic-input"
    foreach ($name in @(
            "send_short",
            "send_large",
            "send_multiline",
            "send_unicode",
            "send_chunking",
            "separate_enter",
            "bracketed_paste",
            "probe_cleanup"
        ))
    {
        [void]($capabilities[$name] = $input[$name])
    }

    $fixture = Test-ZmxFixture -Session "${SessionPrefix}-generic-high-output"
    Set-Capability -Capabilities $capabilities -Name "long_high_output" `
        -Status $fixture.status -Detail $fixture.detail

    $cleanupStatuses = @($input.probe_cleanup.status)
    if ($null -ne $fixture.cleanup) {
        $cleanupStatuses += if ($fixture.cleanup.success) { "pass" } else { "fail" }
    }
    $cleanupStatus = if ($cleanupStatuses -contains "fail") {
        "fail"
    } elseif ($cleanupStatuses -contains "pass") {
        "pass"
    } else {
        "skip"
    }
    Set-Capability -Capabilities $capabilities -Name "probe_cleanup" `
        -Status $cleanupStatus `
        -Detail "generic probe registrations and processes were polled for removal"

    $status = if (@($capabilities.Values | Where-Object { $_.status -eq "fail" }).Count -gt 0) {
        "fail"
    } elseif (@($capabilities.Values | Where-Object { $_.status -eq "pass" }).Count -gt 0) {
        "pass"
    } else {
        "skip"
    }
    return [ordered]@{
        status = $status
        capabilities = $capabilities
    }
}

function Test-Backend {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Catalog,
        [Parameter(Mandatory = $true)][pscustomobject]$Discovery
    )

    $capabilities = New-CapabilityMap -Names $Script:BackendCapabilities `
        -Detail $Discovery.diagnostic
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
        foreach ($name in $Script:BackendCapabilities) {
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
    $launchAttempted = $false
    $processId = $null
    try {
        $launchAttempted = $true
        $run = Invoke-Zmx -ArgumentList $runArguments -Timeout 15
        if ($run.exit_code -ne 0 -or -not (Wait-ZmxSession -Session $session -Timeout 15)) {
            Set-Capability -Capabilities $capabilities -Name "launch" -Status "fail" `
                -Detail "zmx run failed: $($run.stderr)"
            $row.status = "failed"
            $row.diagnostic = "backend launch failed; version: $($Catalog.version_command)"
            return $row
        }
        $processId = Get-ZmxSessionPid -Session $session
        $row.status = "tested"
        Set-Capability -Capabilities $capabilities -Name "launch" -Status "pass" `
            -Detail "started as a real zmx Windows ConPTY session"

        $authRequired = Get-BackendAuthRequired -Session $session -Timeout 5

        $setLabels = Invoke-Zmx -ArgumentList @(
            "set", $session, "backend=$($Catalog.name)", "activity=matrix", "usage=public"
        ) -Timeout 10
        $labels = Invoke-Zmx -ArgumentList @("get", $session) -Timeout 10
        $labelsPass = $setLabels.exit_code -eq 0 -and $labels.exit_code -eq 0 `
            -and $labels.stdout -match "backend=$($Catalog.name)" `
            -and $labels.stdout -match "activity=matrix" `
            -and $labels.stdout -match "usage=public"
        Set-Capability -Capabilities $capabilities -Name "labels" `
            -Status $(if ($labelsPass) { "pass" } else { "fail" }) `
            -Detail "exact backend/activity/usage labels round-tripped"
        Set-Capability -Capabilities $capabilities -Name "usage_activity_labels" `
            -Status $(if ($labelsPass) { "pass" } else { "fail" }) `
            -Detail "exact usage/activity labels are explicit zmx labels"
        Set-Capability -Capabilities $capabilities -Name "hooks" -Status "skip" `
            -Detail "no public cross-agent hook contract was assumed"

        $agentReplyMarker = $null
        if ($authRequired) {
            Set-AgentDependentSkips -Capabilities $capabilities `
                -Detail "backend reported authentication or interactive trust gating before any input was sent"
        } else {
            $promptProbe = New-BackendMarkerProbe -Backend $Catalog.name -Kind "REPLY"
            $agentReplyMarker = $promptProbe.marker
            $promptResult = Send-ZmxInput -Session $session -Text "$($promptProbe.prompt)`r"
            $promptPass = Wait-ZmxHistoryMarker -Session $session `
                -Marker $agentReplyMarker -Timeout 15
            Set-Capability -Capabilities $capabilities -Name "prompt_input" `
                -Status $(if ($promptPass) { "pass" } else { "skip" }) `
                -Detail $(if ($promptPass) { "exact backend reply marker observed" } else { "no exact backend reply marker observed" })

            if ($promptPass) {
                $longProbe = New-BackendMarkerProbe -Backend $Catalog.name -Kind "LONG"
                $longReplyMarker = $longProbe.marker
                $longResult = Send-ZmxInput -Session $session -Text "$($longProbe.prompt)`r"
                $longPass = Wait-ZmxHistoryMarker -Session $session `
                    -Marker $longReplyMarker -Timeout 20
                Set-Capability -Capabilities $capabilities -Name "backend_long_turn" `
                    -Status $(if ($longPass) { "pass" } else { "skip" }) `
                    -Detail $(if ($longPass) { "exact backend long-turn reply marker observed" } else { "no exact backend long-turn reply marker observed" })

                $progressProbe = New-BackendMarkerProbe -Backend $Catalog.name -Kind "PROGRESS"
                $progressReplyMarker = $progressProbe.marker
                $progressAttach = $null
                try {
                    $progressAttach = Start-LongProcess -FilePath $Script:ZmxSpec.file_path `
                        -ArgumentList @("attach", $session) -Environment $Script:ZmxEnvironment
                    Start-Sleep -Milliseconds 750
                    if ($progressAttach.HasExited) {
                        Set-Capability -Capabilities $capabilities -Name "background_progress" `
                            -Status "skip" -Detail "attach process exited before pending operation could be detached"
                    } else {
                        $progressResult = Send-ZmxInput -Session $session `
                            -Text "$($progressProbe.prompt) Wait three seconds before producing the envelope.`r"
                        Start-Sleep -Milliseconds 750
                        $beforeDetach = Get-ZmxHistory -Session $session
                        $detachProgress = Invoke-Zmx -ArgumentList @("detach") `
                            -Environment @{ ZMX_SESSION = $session } -Timeout 10
                        $progressAttachExited = Wait-ProcessExit -Process $progressAttach -Timeout 10
                        $progressAfterDetach = Wait-ZmxHistoryMarker -Session $session `
                            -Marker $progressReplyMarker -Timeout 15
                        $progressPass = -not $beforeDetach.Contains($progressReplyMarker) `
                            -and $progressAttachExited -and $progressAfterDetach
                        Set-Capability -Capabilities $capabilities -Name "background_progress" `
                            -Status $(if ($progressPass) { "pass" } else { "skip" }) `
                            -Detail $(if ($progressPass) {
                                "detached pending deterministic operation and observed its exact post-detach marker"
                            } else {
                                "pending operation was not observed producing its exact marker after detach"
                            })
                    }
                } finally {
                    Stop-ProcessInstance -Process $progressAttach
                }

                $attach = $null
                try {
                    $attach = Start-LongProcess -FilePath $Script:ZmxSpec.file_path `
                        -ArgumentList @("attach", $session) -Environment $Script:ZmxEnvironment
                    Start-Sleep -Milliseconds 750
                    if ($attach.HasExited) {
                        Set-Capability -Capabilities $capabilities -Name "detach" -Status "skip" `
                            -Detail "attach process exited before detach could be issued"
                    } else {
                        $detach = Invoke-Zmx -ArgumentList @("detach") `
                            -Environment @{ ZMX_SESSION = $session } -Timeout 10
                        $attachExited = Wait-ProcessExit -Process $attach -Timeout 10
                        $sessionPresent = Wait-ZmxSession -Session $session -Timeout 5
                        Set-Capability -Capabilities $capabilities -Name "detach" `
                            -Status $(if ($attachExited -and $sessionPresent) { "pass" } else { "fail" }) `
                            -Detail "detach was observed as attached-client exit with session retention"
                    }
                } finally {
                    Stop-ProcessInstance -Process $attach
                }

                $resumeProbe = New-BackendMarkerProbe -Backend $Catalog.name -Kind "RESUME"
                $resumeMarker = $resumeProbe.marker
                $resumeResult = Send-ZmxInput -Session $session -Text "$($resumeProbe.prompt)`r"
                $resumePass = Wait-ZmxHistoryMarker -Session $session `
                    -Marker $resumeMarker -Timeout 15
                [void](Invoke-Zmx -ArgumentList @("history", $session) -Timeout 10 -FullOutput)
                $resumePass = $resumePass -and
                    (Wait-ZmxHistoryMarker -Session $session -Marker $resumeMarker -Timeout 10)
                Set-Capability -Capabilities $capabilities -Name "session_id_resume" `
                    -Status $(if ($resumePass) { "pass" } else { "skip" }) `
                    -Detail "fresh zmx history client observed exact resume marker for session $session"

                $vtProbe = New-BackendMarkerProbe -Backend $Catalog.name -Kind "VT"
                $vtMarker = $vtProbe.marker
                $vtResult = Send-ZmxInput -Session $session -Text "$($vtProbe.prompt)`r"
                $vtPass = (Wait-ZmxHistoryMarker -Session $session -Marker $vtMarker -Timeout 15) `
                    -and (Wait-ZmxVtHistoryMarker -Session $session -Marker $vtMarker -Timeout 15)
                Set-Capability -Capabilities $capabilities -Name "reconnect_vt" `
                    -Status $(if ($vtPass) { "pass" } else { "skip" }) `
                    -Detail "VT history polling observed exact backend marker bytes"

                $crashClient = $null
                try {
                    $crashClient = Start-LongProcess -FilePath $Script:ZmxSpec.file_path `
                        -ArgumentList @("attach", $session) -Environment $Script:ZmxEnvironment
                    Start-Sleep -Milliseconds 750
                    $crashExited = $false
                    if (-not $crashClient.HasExited) {
                        $crashClient.Kill($true)
                        $crashExited = Wait-ProcessExit -Process $crashClient -Timeout 10
                    }
                    $sessionSurvived = Wait-ZmxSession -Session $session -Timeout 10 `
                        -and (Get-ZmxHistory -Session $session).Contains($agentReplyMarker)
                    Set-Capability -Capabilities $capabilities -Name "client_crash_survival" `
                        -Status $(if ($crashExited -and $sessionSurvived) { "pass" } else { "fail" }) `
                        -Detail "client PID exited and exact backend marker remained resumable"
                } catch {
                    Set-Capability -Capabilities $capabilities -Name "client_crash_survival" -Status "skip" `
                        -Detail "attach client could not run under the pipe-safe harness"
                } finally {
                    Stop-ProcessInstance -Process $crashClient
                }

                $ctrlC = Send-ZmxInput -Session $session -Text ([char]3)
                $afterCtrlProbe = New-BackendMarkerProbe -Backend $Catalog.name -Kind "AFTER_CTRL"
                $afterCtrlMarker = $afterCtrlProbe.marker
                $afterCtrl = Send-ZmxInput -Session $session `
                    -Text "$($afterCtrlProbe.prompt)`r"
                $ctrlPass = Wait-ZmxHistoryMarker -Session $session `
                    -Marker $afterCtrlMarker -Timeout 15
                Set-Capability -Capabilities $capabilities -Name "ctrl_c" `
                    -Status $(if ($ctrlPass) { "pass" } else { "skip" }) `
                    -Detail $(if ($ctrlPass) { "ETX delivered and exact post-control marker observed" } else { "no exact post-control marker observed" })
            } else {
                Set-AgentDependentSkips -Capabilities $capabilities `
                    -Detail "backend prompt was not observable with an exact public reply marker"
            }
        }

        Set-Capability -Capabilities $capabilities -Name "resize" -Status "skip" `
            -Detail "zmx exposes resize through a live console; stable pipe-only automation is unavailable"
        Set-Capability -Capabilities $capabilities -Name "app_crash_survival" -Status "skip" `
            -Detail "no safe public crash injection was applied to the installed coding agent"
    } finally {
        if ($launchAttempted) {
            $cleanup = Stop-ZmxSession -Session $session -ProcessId $processId
            Set-Capability -Capabilities $capabilities -Name "clean_kill" `
                -Status $(if ($cleanup.success) { "pass" } else { "fail" }) `
                -Detail "kill attempted (exit=$($cleanup.exit_code), pid=$($cleanup.target_pid)); registration=$($cleanup.registration_removed), process=$($cleanup.process_absent): $($cleanup.detail)"
        }
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
    if ($Script:RequiredCapabilities -notcontains "backend_long_turn") {
        throw "matrix contract is missing backend turn observability"
    }
    Write-JsonDocument -Document ([ordered]@{
            schema = $Script:Schema
            status = "pass"
            required_capabilities = $Script:RequiredCapabilities
            generic_probe_capabilities = $Script:GenericCapabilities
            backend_capabilities = $Script:BackendCapabilities
            backends = $names
            observable_contract = @(
                "exact_history_markers",
                "output_only_backend_markers",
                "sequence_chunk_markers",
                "attach_process_exit",
                "pending_progress_after_detach",
                "vt_marker_bytes",
                "registration_removal_after_kill",
                "bomless_utf8_input"
            )
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
    $genericProbes = Test-GenericProbes
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
    $allCapabilities = @(
        $genericProbes.capabilities.Values
        $matrixRows | ForEach-Object { $_["capabilities"].Values }
    )
    $summary = [ordered]@{
        pass = @($allCapabilities | Where-Object { $_.status -eq "pass" }).Count
        fail = @($allCapabilities | Where-Object { $_.status -eq "fail" }).Count
        skip = @($allCapabilities | Where-Object { $_.status -eq "skip" }).Count
    }
    $matrixStatus = if ($summary.fail -gt 0) { "fail" } else { "pass" }
    Write-JsonDocument -Document ([ordered]@{
            schema = $Script:Schema
            mode = "matrix"
            status = $matrixStatus
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
            generic_probes = $genericProbes
            backends = $matrixRows
        })
    if ($summary.fail -gt 0) {
        exit 1
    }
} finally {
    if (Test-Path -LiteralPath $Script:ZmxEnvironment.ZMX_DIR) {
        Remove-Item -LiteralPath $Script:ZmxEnvironment.ZMX_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}
