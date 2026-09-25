param(
    [string] $Zmx = (Join-Path $PSScriptRoot '..\zig-out\bin\zmx.exe'),
    [string] $ArtifactsDirectory,
    [string] $WorkerToken,
    [switch] $SelfTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This test requires native Windows ConPTY.' }
$Zmx = (Resolve-Path -LiteralPath $Zmx).Path

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function ConvertFrom-StartupInfo([string] $Text, [string] $Session, [string] $Cwd) {
    $pattern = '\A(?<session>[^\t\r\n]+)\tclients=(?<clients>0|[1-9][0-9]*)\tpid=(?<pid>[1-9][0-9]*)\tcmd=\tcwd=(?<cwd>[^\t\r\n]+)\r?\n\z'
    $record = [regex]::Match($Text, $pattern)
    Require ($record.Success) 'Malformed startup info record.'
    Require ($record.Groups['session'].Value -ceq $Session) 'Unexpected startup info session.'
    Require ([string]::Equals($record.Groups['cwd'].Value, $Cwd, [StringComparison]::OrdinalIgnoreCase)) 'Unexpected startup info cwd.'
    return [pscustomobject]@{
        Ready = [ulong]::Parse($record.Groups['clients'].Value) -gt 0
        BackendPid = [int]::Parse($record.Groups['pid'].Value)
    }
}

if ($WorkerToken) {
    $gate = [Threading.EventWaitHandle]::OpenExisting("Local\zmx-startup-$WorkerToken")
    try { Require ($gate.WaitOne(15000)) 'Timed out waiting for job ownership.' }
    finally { $gate.Dispose() }
    $commands = [Collections.Generic.List[object]]::new()
    $sessions = [Collections.Generic.List[object]]::new()
    $passed = $false
    $expectedCwd = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    function Start-Zmx([string[]] $Arguments) {
        $start = [Diagnostics.ProcessStartInfo]::new($Zmx)
        $start.WorkingDirectory = $expectedCwd
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $record = [pscustomobject]@{
            Pid = $process.Id; CreatedUtc = $process.StartTime.ToUniversalTime()
            Arguments = $Arguments; ExitCode = $null; Stdout = ''; Stderr = ''
        }
        $commands.Add($record)
        return [pscustomobject]@{
            Process = $process; Record = $record
            Output = $process.StandardOutput.ReadToEndAsync()
            Error = $process.StandardError.ReadToEndAsync()
        }
    }

    function Finish-Zmx($Run, [bool] $DrainOutput = $true, [int] $TimeoutMs = 5000) {
        Require ($Run.Process.WaitForExit($TimeoutMs)) "Command timed out: $($Run.Record.Arguments)"
        $Run.Record.ExitCode = $Run.Process.ExitCode
        if (-not $DrainOutput) { return $Run.Record }
        Require ($Run.Output.Wait(5000)) 'stdout did not drain.'
        Require ($Run.Error.Wait(5000)) 'stderr did not drain.'
        $Run.Record.Stdout = $Run.Output.Result
        $Run.Record.Stderr = $Run.Error.Result
        return $Run.Record
    }

    function Invoke-Zmx([string[]] $Arguments, [bool] $AllowFailure = $false) {
        $run = Start-Zmx $Arguments
        try {
            $record = Finish-Zmx $run
            if (-not $AllowFailure) {
                Require ($record.ExitCode -eq 0) "Command failed: $Arguments`n$($record.Stderr)"
            }
            return $record
        } finally { $run.Process.Dispose() }
    }

    function Read-Info([string] $Raw, $Attach) {
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        do {
            Require (-not $Attach.Process.HasExited) "Attach exited before readiness: $Raw"
            $record = Invoke-Zmx @('info', $Raw) $true
            Require (-not $Attach.Process.HasExited) "Attach exited while checking readiness: $Raw"
            if ($record.ExitCode -eq 0) {
                $qualified = "$env:ZMX_SESSION_PREFIX$Raw"
                $info = ConvertFrom-StartupInfo $record.Stdout $qualified $expectedCwd
                if ($info.Ready) { return $info.BackendPid }
            } else {
                Require ($record.Stderr -match 'ConnectionRefused|Timeout') "Unexpected info failure: $($record.Stderr)"
            }
            Start-Sleep -Milliseconds 20
        } while ([datetime]::UtcNow -lt $deadline)
        throw "Attach never became ready: $Raw"
    }

    function Wait-State([string] $Raw, $Attach, [string] $Expected) {
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        do {
            Require (-not $Attach.Process.HasExited) 'Attach exited while waiting for shell output.'
            $history = Invoke-Zmx @('history', $Raw)
            if ($history.Stdout.Contains($Expected)) { return }
            Start-Sleep -Milliseconds 20
        } while ([datetime]::UtcNow -lt $deadline)
        throw "Shell did not produce expanded state: $Expected"
    }

    try {
        foreach ($index in 0..2) {
            $raw = [guid]::NewGuid().ToString()
            $qualified = "$env:ZMX_SESSION_PREFIX$raw"
            $attach = Start-Zmx @('attach', $raw)
            $reattach = $null
            $backend = $null
            $daemon = $null
            try {
                $backendId = Read-Info $raw $attach
                $backendRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$backendId"
                Require ($null -ne $backendRecord -and $backendRecord.Name -ieq 'cmd.exe') 'Default backend is not cmd.exe.'
                $daemonId = [int]$backendRecord.ParentProcessId
                $daemonRecord = Get-CimInstance Win32_Process -Filter "ProcessId=$daemonId"
                Require ($null -ne $daemonRecord) 'Daemon identity is missing.'
                Require ($daemonRecord.ParentProcessId -eq $attach.Process.Id) 'Daemon does not descend from this attach.'
                Require ($daemonRecord.ExecutablePath -ieq $Zmx) 'Daemon executable differs from the tested binary.'
                Require ($daemonRecord.CommandLine -match ('--daemon\s+"?' + [regex]::Escape($qualified) + '"?(?:\s|$)')) 'Daemon session qualification differs from attach.'
                $backend = [Diagnostics.Process]::GetProcessById($backendId)
                $daemon = [Diagnostics.Process]::GetProcessById($daemonId)
                $backendUtc = $backend.StartTime.ToUniversalTime()
                Require ($backendUtc -ge $attach.Record.CreatedUtc) 'Backend predates this attach.'
                $null = $backend.Handle
                $null = $daemon.Handle
                Require ($daemon.StartTime.ToUniversalTime() -ge $attach.Record.CreatedUtc -and $daemon.StartTime.ToUniversalTime() -le $backendUtc) 'Daemon ancestry timestamps differ.'
                $state = "$WorkerToken-$index"
                $attach.Process.StandardInput.Write("set ZMX_STARTUP_STATE=$state`r")
                $attach.Process.StandardInput.Write("echo zmx-first-%ZMX_STARTUP_STATE%-end`r")
                $attach.Process.StandardInput.Write("echo zmx-name-%ZMX_SESSION%-end`r")
                $attach.Process.StandardInput.Flush()
                Wait-State $raw $attach "zmx-first-$state-end"
                Wait-State $raw $attach "zmx-name-$qualified-end"
                $null = Invoke-Zmx @('detach', $raw)
                # The detached daemon may retain inherited stdio handles until it exits.
                $detached = Finish-Zmx $attach $false
                Require ($detached.ExitCode -eq 0) "Detach failed: $($detached.Stderr)"
                Require (-not $backend.HasExited -and -not $daemon.HasExited) 'Detach ended the session.'

                $reattach = Start-Zmx @('attach', $raw)
                Require ((Read-Info $raw $reattach) -eq $backendId) 'Reattach replaced the backend.'
                Require ($backend.StartTime.ToUniversalTime() -eq $backendUtc) 'Backend identity changed across reattach.'
                $reattach.Process.StandardInput.Write("echo zmx-second-%ZMX_STARTUP_STATE%-end`r")
                $reattach.Process.StandardInput.Flush()
                Wait-State $raw $reattach "zmx-second-$state-end"
                $null = Invoke-Zmx @('detach', $raw)
                $detachedAgain = Finish-Zmx $reattach $false
                Require ($detachedAgain.ExitCode -eq 0) 'Second detach failed.'
                $null = Invoke-Zmx @('kill', $raw)
                Require ($backend.WaitForExit(5000)) 'Backend survived session kill.'
                Require ($daemon.WaitForExit(5000)) 'Daemon survived session kill.'
                $null = Finish-Zmx $attach
                $null = Finish-Zmx $reattach
                $sessions.Add([pscustomobject]@{
                    Raw = $raw; Qualified = $qualified; BackendPid = $backendId
                    BackendCreatedUtc = $backendUtc; DaemonPid = $daemonId
                    StatePreserved = $true
                })
            } finally {
                if ($reattach) { $reattach.Process.Dispose() }
                $attach.Process.Dispose()
                if ($backend) { $backend.Dispose() }
                if ($daemon) { $daemon.Dispose() }
                # The outer job owns every remaining child, including late daemon children.
            }
        }
        $passed = $true
    } finally {
        [pscustomobject]@{
            Passed = $passed; Sessions = @($sessions); Commands = @($commands)
        } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $ArtifactsDirectory 'startup.json')
    }
    exit 0
}

Add-Type @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ZmxStartupJob {
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
        public Basic Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, IntPtr name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref Extended value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, IntPtr value, uint size, IntPtr length);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);
    public static IntPtr Create() {
        var job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
        if (job == IntPtr.Zero) throw new Win32Exception();
        var limits = new Extended();
        limits.Basic.Flags = 0x2000;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Extended>())) {
            var error = new Win32Exception();
            CloseHandle(job);
            throw error;
        }
        return job;
    }
    public static int[] Pids(IntPtr job) {
        const int size = 32768;
        var buffer = Marshal.AllocHGlobal(size);
        try {
            if (!QueryInformationJobObject(job, 3, buffer, size, IntPtr.Zero)) throw new Win32Exception();
            int count = Marshal.ReadInt32(buffer, 4);
            var result = new int[count];
            for (int i=0; i<count; ++i) result[i] = checked((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size));
            return result;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static bool HasVisibleWindow(int[] pids) {
        var owned = new HashSet<int>(pids);
        bool found = false;
        EnumWindows((window, parameter) => {
            int pid;
            GetWindowThreadProcessId(window, out pid);
            if (owned.Contains(pid) && IsWindowVisible(window)) found = true;
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Complete-StartupRun(
    $Job, $Gate, $Worker, $WorkerUtc, [bool] $Assigned, $Output, $Stderr,
    [scriptblock] $Report,
    [scriptblock] $Query = { param($Handle) [ZmxStartupJob]::Pids($Handle) },
    [scriptblock] $Terminate = {
        param($Handle)
        Require ([ZmxStartupJob]::TerminateJobObject($Handle, 124)) 'Job termination failed.'
    }
) {
    $errors = [Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{ Failures = $errors; Verified = $false; Remaining = $null }
    try {
        try {
            if ($Worker -and -not $Assigned -and -not $Worker.HasExited) {
                Require ($Worker.StartTime.ToUniversalTime() -eq $WorkerUtc) 'Unassigned worker identity changed.'
                $Worker.Kill()
                Require ($Worker.WaitForExit(5000)) 'Unassigned worker survived cleanup.'
            }
        } catch { $errors.Add("Unassigned worker cleanup: $_") }
        if ($Job) {
            try { & $Terminate $Job.DangerousGetHandle() }
            catch { $errors.Add("Job termination: $_") }
            try {
                $deadline = [datetime]::UtcNow.AddSeconds(5)
                do {
                    $result.Remaining = @(& $Query $Job.DangerousGetHandle())
                    if ($result.Remaining.Count -eq 0) { break }
                    Start-Sleep -Milliseconds 20
                } while ([datetime]::UtcNow -lt $deadline)
                $result.Verified = $result.Remaining.Count -eq 0
                Require ($result.Verified) "Owned processes survived: $($result.Remaining)"
            } catch { $errors.Add("Survivor verification: $_") }
        }
        foreach ($stream in @(@('stdout', $Output), @('stderr', $Stderr))) {
            if ($stream[1]) {
                try { Require ($stream[1].Wait(5000)) "$($stream[0]) did not drain." }
                catch { $errors.Add("Stream capture: $_") }
            }
        }
        if ($Report) {
            try { & $Report $result }
            catch { $errors.Add("Cleanup report: $_") }
        }
    } finally {
        # Closing the job is the final kill-on-close barrier, even if verification
        # or reporting failed. One disposal failure must not skip another handle.
        foreach ($resource in @($Job, $Gate, $Worker)) {
            if ($resource) {
                try { $resource.Dispose() }
                catch { $errors.Add("Resource disposal: $_") }
            }
        }
    }
    return $result
}

if ($SelfTest) {
    $cwd = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $valid = "test-session`tclients=1`tpid=123`tcmd=`tcwd=$cwd`n"
    $ready = ConvertFrom-StartupInfo $valid 'test-session' $cwd
    Require ($ready.Ready -and $ready.BackendPid -eq 123) 'Valid info was not ready.'
    Require (-not (ConvertFrom-StartupInfo ($valid.Replace('clients=1', 'clients=0')) 'test-session' $cwd).Ready) 'clients=0 must remain pending.'
    $invalid = @(
        $valid.Replace($cwd, 'C:\wrong'),
        ($valid + $valid),
        ($valid + 'extra'),
        $valid.TrimEnd("`n"),
        $valid.Replace('test-session', 'wrong-session'),
        $valid.Replace("cmd=`t", "cmd=cmd.exe`t"),
        $valid.Replace('clients=1', 'clients=-1'),
        $valid.Replace('clients=1', 'clients=18446744073709551616'),
        $valid.Replace('pid=123', 'pid=0'),
        $valid.Replace('pid=123', 'pid=2147483648')
    )
    foreach ($text in $invalid) {
        $rejected = $false
        try { $null = ConvertFrom-StartupInfo $text 'test-session' $cwd }
        catch { $rejected = $true }
        Require $rejected "Malformed info was accepted: $text"
    }
    foreach ($case in @('report', 'query', 'unassigned')) {
        $job = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([ZmxStartupJob]::Create(), $true)
        $gate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset)
        $worker = $null
        $observer = $null
        try {
            $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '[Threading.Thread]::Sleep(60000)')) {
                $start.ArgumentList.Add($argument)
            }
            $worker = [Diagnostics.Process]::Start($start)
            $workerUtc = $worker.StartTime.ToUniversalTime()
            $observer = [Diagnostics.Process]::GetProcessById($worker.Id)
            $workerHandle = $worker.SafeHandle
            $observerHandle = $observer.SafeHandle
            $gateHandle = $gate.SafeWaitHandle
            $assigned = $case -ne 'unassigned'
            if ($assigned) {
                Require ([ZmxStartupJob]::AssignProcessToJobObject($job.DangerousGetHandle(), $workerHandle.DangerousGetHandle())) 'Self-test job assignment failed.'
            }
            $options = @{}
            if ($case -eq 'report') {
                $options.Report = { throw [IO.IOException]::new('injected report-write failure') }
            } elseif ($case -eq 'query') {
                $options.Query = { throw [ComponentModel.Win32Exception]::new(6, 'injected query failure') }
                $options.Terminate = { throw [ComponentModel.Win32Exception]::new(6, 'injected termination failure') }
            }
            $result = Complete-StartupRun $job $gate $worker $workerUtc $assigned $null $null @options
            Require ($job.IsClosed -and $gateHandle.IsClosed -and $workerHandle.IsClosed) "$case skipped resource disposal."
            Require (-not $observerHandle.IsClosed -and $observer.WaitForExit(5000)) "$case left its held process alive."
            if ($case -eq 'query') {
                Require (-not $result.Verified -and $result.Failures.Count -eq 2) 'Query/termination failures were hidden.'
            } elseif ($case -eq 'report') {
                Require ($result.Verified -and $result.Failures.Count -eq 1) 'Report failure skipped verification or was hidden.'
            } else {
                Require ($result.Verified -and $result.Failures.Count -eq 0) 'Unassigned worker cleanup failed.'
            }
            Write-Output "PASS: $case failure-path handles closed and held worker exited."
        } finally {
            try {
                if ($observer -and -not $observer.HasExited) {
                    $observer.Kill()
                    Require ($observer.WaitForExit(5000)) 'Self-test emergency cleanup failed.'
                }
            } finally {
                $job.Dispose()
                $gate.Dispose()
                if ($worker) { $worker.Dispose() }
                if ($observer) { $observer.Dispose() }
            }
        }
    }
    Write-Output "PASS: $($invalid.Count + 2) strict startup info cases and three native cleanup failure paths."
    return
}

$token = [guid]::NewGuid().ToString('N')
$runtime = Join-Path ([IO.Path]::GetTempPath()) "zx$($token.Substring(0,8))"
Require (-not (Test-Path -LiteralPath $runtime)) "Runtime collision: $runtime"
# Let the provider create its root with the current token SID as owner.
# An elevated runner's generic directory creation can select Administrators.
if (-not $ArtifactsDirectory) {
    $ArtifactsDirectory = Join-Path ([IO.Path]::GetTempPath()) "zmx-startup-results-$token"
}
$null = New-Item -ItemType Directory -Path $ArtifactsDirectory -Force
$ArtifactsDirectory = (Resolve-Path -LiteralPath $ArtifactsDirectory).Path
$gate = $null
$job = $null
$worker = $null
$workerUtc = $null
$assigned = $false
$output = $null
$stderr = $null
$owned = @{}
$exitCode = $null
$failure = $null
try {
    $gate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, "Local\zmx-startup-$token")
    $job = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([ZmxStartupJob]::Create(), $true)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Zmx', $Zmx, '-ArtifactsDirectory', $ArtifactsDirectory, '-WorkerToken', $token)) {
        $start.ArgumentList.Add($argument)
    }
    $start.Environment['ZMX_DIR'] = $runtime
    $start.Environment['ZMX_SESSION_PREFIX'] = "t$($token.Substring(0,8))-"
    $null = $start.Environment.Remove('ZMX_SESSION')
    $worker = [Diagnostics.Process]::Start($start)
    $workerUtc = $worker.StartTime.ToUniversalTime()
    $output = $worker.StandardOutput.ReadToEndAsync()
    $stderr = $worker.StandardError.ReadToEndAsync()
    Require ([ZmxStartupJob]::AssignProcessToJobObject($job.DangerousGetHandle(), $worker.Handle)) 'Cannot assign startup worker to its cleanup job.'
    $assigned = $true
    $null = $gate.Set()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $pids = [ZmxStartupJob]::Pids($job.DangerousGetHandle())
        Require (-not [ZmxStartupJob]::HasVisibleWindow($pids)) 'An owned process created a visible window.'
        foreach ($childId in $pids) {
            $record = Get-CimInstance Win32_Process -Filter "ProcessId=$childId"
            if ($record) {
                $utc = ([datetime]$record.CreationDate).ToUniversalTime()
                $owned["${childId}:$($utc.Ticks)"] = [pscustomobject]@{
                    Pid = $childId; ParentPid = $record.ParentProcessId
                    CreatedUtc = $utc; CreatedUtcTicks = $utc.Ticks
                    CommandLine = $record.CommandLine
                }
            }
        }
        if ($worker.WaitForExit(50)) { break }
    } while ($clock.Elapsed.TotalSeconds -lt 90)
    Require ($worker.HasExited) 'Startup integration exceeded its outer deadline.'
    $exitCode = $worker.ExitCode
} catch {
    $failure = $_.ToString()
} finally {
    $cleanup = Complete-StartupRun $job $gate $worker $workerUtc $assigned $output $stderr -Report {
        param($Result)
        if ($output -and $output.IsCompletedSuccessfully) { $output.Result | Set-Content (Join-Path $ArtifactsDirectory 'stdout.log') }
        if ($stderr -and $stderr.IsCompletedSuccessfully) { $stderr.Result | Set-Content (Join-Path $ArtifactsDirectory 'stderr.log') }
        [pscustomobject]@{
            Executable = $Zmx; BinarySha256 = (Get-FileHash -LiteralPath $Zmx).Hash
            ScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
            Runtime = $runtime; Prefix = "t$($token.Substring(0,8))-"
            ExitCode = $exitCode; Failure = $failure; CleanupFailures = @($Result.Failures)
            CleanupVerified = $Result.Verified
            Processes = @($owned.Values); RemainingOwnedPids = $Result.Remaining
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ArtifactsDirectory 'ownership.json')
    }
}
Require ($cleanup.Verified -and $cleanup.Failures.Count -eq 0) "Owned cleanup failed: $($cleanup.Failures -join '; ')"
Require (-not $failure) "Startup integration failed: $failure"
if ($exitCode -ne 0) {
    Get-Content -LiteralPath (Join-Path $ArtifactsDirectory 'stderr.log')
    throw "Startup integration exited $exitCode; evidence: $ArtifactsDirectory"
}
Write-Output "PASS: three real cmd/ConPTY attach, state, detach and reattach scenarios; zero owned survivors. Evidence: $ArtifactsDirectory"
