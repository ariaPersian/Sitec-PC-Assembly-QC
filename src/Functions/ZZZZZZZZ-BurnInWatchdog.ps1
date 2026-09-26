# Production watchdog for the concurrent burn-in engine.
# The actual CPU/RAM/NVMe/GPU workload runs in an isolated PowerShell child process.
# If a driver, CIM provider, sensor poll, memory pass, WinSAT or DiskSpd hangs, the
# parent QC worker can terminate the entire process tree and continue to a useful
# FAIL report instead of leaving the operator at 100% progress indefinitely.

$script:SitecFullSystemBurnInInProcess = ${function:Invoke-SitecFullSystemBurnIn}

function New-SitecBurnInTimeoutResult {
    param(
        [int]$DurationSeconds,
        [double]$ActualSeconds,
        [string]$Reason='Burn-in watchdog timeout'
    )
    $selection=@()
    try { $selection=@(Get-SitecBenchmarkSelection) } catch {}
    function Sel([string]$Name){$selection -contains $Name}
    [pscustomobject]@{
        Status='FAIL'
        Required=$true
        Cancelled=$false
        Error=$Reason
        TimedOut=$true
        DurationSeconds=$DurationSeconds
        ActualSeconds=[math]::Round($ActualSeconds,1)
        Selection=@($selection)
        CpuStress=[pscustomobject]@{
            Enabled=(Sel 'CPU');Status=$(if(Sel 'CPU'){'TIMEOUT'}else{'SKIPPED'});CoverageMode=$(if(Sel 'CPU'){'MaximumSafe'}else{'None'})
            Seconds=0;LogicalProcessors=[Environment]::ProcessorCount;Threads=0;ThreadCoveragePercent=0;DutyPercent=0;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0
        }
        MemoryVerification=[pscustomobject]@{
            Enabled=(Sel 'Memory');Status=$(if(Sel 'Memory'){'TIMEOUT'}else{'SKIPPED'});RequestedMB=0;AllocatedMB=0;VerifiedMB=0;Errors=$(if(Sel 'Memory'){[long]::MaxValue}else{0})
            Seconds=0;Passes=0;CoverageMode=$(if(Sel 'Memory'){'MaximumSafe'}else{'None'});TargetSystemUsagePercent=$null;ExpectedSystemUsagePercent=$null
            AllocationMode=$(if(Sel 'Memory'){'MaximumSafe'}else{'None'});SafeCoverageTargetMB=0;AllocationCoveragePercent=0;ReserveMB=0
        }
        DiskStress=[pscustomobject]@{
            Enabled=(Sel 'Disk');Status=$(if(Sel 'Disk'){'TIMEOUT'}else{'SKIPPED'});CoverageMode=$(if(Sel 'Disk'){'MaximumSafe'}else{'None'})
            ProcessExitCode=$null;ReadMBps=$null;ReadIOPS=$null;AverageReadLatencyMs=$null;TargetSizeMB=0;FreeBeforeMB=0;ReserveFreeMB=0
            BlockSizeKB=0;QueueDepth=0;Threads=0;WritePercent=0;CacheMode='None';ForcedStop=$true;Error=$Reason;XmlPath='';StdErrPath=''
        }
        GraphicsStress=[pscustomobject]@{
            Enabled=(Sel 'Graphics');Required=(Sel 'Graphics');Status=$(if(Sel 'Graphics'){'TIMEOUT'}else{'SKIPPED'});CoverageMode=$(if(Sel 'Graphics'){'MaximumSafe'}else{'None'})
            WorkloadMode=$(if(Sel 'Graphics'){'Direct3D-ALU'}else{'None'});TargetAveragePercent=0;TargetPeakPercent=0;NormalWindows=0;GlassWindows=0;Resolution=''
            Offscreen=$true;NoLock=$false;ProcessExitCode=$null;Engine='Isolated burn-in child process';ForcedStop=$true;Error=$Reason;OutputPath='';StdErrPath=''
        }
        Utilization=(Get-SitecLoadSummary @())
        Sensors=@()
        LoadSamples=@()
    }
}
function New-SitecBurnInCancelledResult {
    param(
        [int]$DurationSeconds,
        [double]$ActualSeconds,
        [string]$Reason='Benchmark cancelled by operator.'
    )
    $selection=@()
    try { $selection=@(Get-SitecBenchmarkSelection) } catch {}
    function Sel([string]$Name){$selection -contains $Name}
    [pscustomobject]@{
        Status='CANCELLED'
        Required=$true
        Cancelled=$true
        TimedOut=$false
        Error=$Reason
        DurationSeconds=$DurationSeconds
        ActualSeconds=[math]::Round($ActualSeconds,1)
        Selection=@($selection)
        CpuStress=[pscustomobject]@{Enabled=(Sel 'CPU');Status=$(if(Sel 'CPU'){'CANCELLED'}else{'SKIPPED'});Seconds=0;Threads=0;DutyPercent=0;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0}
        MemoryVerification=[pscustomobject]@{Enabled=(Sel 'Memory');Status=$(if(Sel 'Memory'){'CANCELLED'}else{'SKIPPED'});RequestedMB=0;AllocatedMB=0;VerifiedMB=0;Errors=0;Seconds=0;Passes=0;TargetSystemUsagePercent=$null}
        DiskStress=[pscustomobject]@{Enabled=(Sel 'Disk');Status=$(if(Sel 'Disk'){'CANCELLED'}else{'SKIPPED'});ReadMBps=$null;ReadIOPS=$null;AverageReadLatencyMs=$null;Error=$Reason}
        GraphicsStress=[pscustomobject]@{Enabled=(Sel 'Graphics');Required=(Sel 'Graphics');Status=$(if(Sel 'Graphics'){'CANCELLED'}else{'SKIPPED'});Engine='Cancelled by operator';Error=$Reason}
        Utilization=(Get-SitecLoadSummary @())
        Sensors=@()
        LoadSamples=@()
    }
}

function Invoke-SitecFullSystemBurnIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)

    # Inside the isolated child process, call the production implementation that
    # was loaded immediately before this watchdog override.
    if ($env:SITECQC_BURNIN_CHILD -eq '1') {
        return & $script:SitecFullSystemBurnInInProcess -Context $Context -RunPath $RunPath
    }

    $cfg=$Context.Settings.BurnIn
    if ($null -eq $cfg -or -not [bool]$cfg.Enabled) {
        return & $script:SitecFullSystemBurnInInProcess -Context $Context -RunPath $RunPath
    }

    $duration=[int]$cfg.DurationSeconds
    if ($duration -lt 30) { $duration=30 }
    $grace=60
    if ($cfg.PSObject.Properties['HardTimeoutGraceSeconds']) {
        $grace=[math]::Max(15,[int]$cfg.HardTimeoutGraceSeconds)
    }
    $watchdogSeconds=$duration+$grace

    $diagDir=Join-Path $RunPath 'diagnostics'
    New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    $resultPath=Join-Path $diagDir 'burnin-child-result.json'
    $errorPath=Join-Path $diagDir 'burnin-child-error.json'
    $stdoutPath=Join-Path $diagDir 'burnin-child-stdout.log'
    $stderrPath=Join-Path $diagDir 'burnin-child-stderr.log'
    @($resultPath,$errorPath,$stdoutPath,$stderrPath) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }

    $modulePath=Join-Path $Context.ProjectRoot 'src\Sitec.QC.psm1'
    $dataRoot=[string]$Context.Settings.DataRoot

    # EncodedCommand avoids quoting bugs with ProgramData/run paths and preserves Unicode.
    $moduleEsc=$modulePath.Replace("'","''")
    $runEsc=$RunPath.Replace("'","''")
    $dataEsc=$dataRoot.Replace("'","''")
    $resultEsc=$resultPath.Replace("'","''")
    $errorEsc=$errorPath.Replace("'","''")
    $child=@"
`$ErrorActionPreference='Stop'
`$env:SITECQC_BURNIN_CHILD='1'
Import-Module '$moduleEsc' -Force
`$ctx=Get-SitecContext -DataRoot '$dataEsc'
try {
    `$r=Invoke-SitecFullSystemBurnIn -Context `$ctx -RunPath '$runEsc'
    `$r | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath '$resultEsc' -Encoding UTF8
    exit 0
} catch {
    `$e=[pscustomobject]@{
        Time=(Get-Date).ToString('o')
        Message=`$_.Exception.Message
        ExceptionType=`$_.Exception.GetType().FullName
        FullyQualifiedErrorId=`$_.FullyQualifiedErrorId
        ScriptStackTrace=`$_.ScriptStackTrace
        PositionMessage=`$_.InvocationInfo.PositionMessage
    }
    `$e | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath '$errorEsc' -Encoding UTF8
    exit 1
}
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))

    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'START' -Message ("Launching isolated burn-in: target {0}s, hard deadline {1}s." -f $duration,$watchdogSeconds) -Data ([pscustomobject]@{DurationSeconds=$duration;GraceSeconds=$grace;HardDeadlineSeconds=$watchdogSeconds})

    $started=Get-Date
    $proc=$null
    try {
        $proc=Start-Process -FilePath 'powershell.exe' -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -EncodedCommand {0}" -f $encoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $deadline=$started.AddSeconds($watchdogSeconds)
        while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
            if(Test-SitecCancellationRequested){
                $elapsed=((Get-Date)-$started).TotalSeconds
                try { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } catch { try { $proc.Kill() } catch {} }
                $reason='Benchmark cancelled by operator.'
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'CANCELLED' -Level 'WARNING' -Message $reason -Data ([pscustomobject]@{Pid=$proc.Id;ElapsedSeconds=[math]::Round($elapsed,1)})
                Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 80 -ElapsedSeconds $elapsed -RemainingSeconds 0 -State 'CANCELLING' -Message 'Cancellation requested; benchmark process tree stopped. Finalizing partial evidence.'
                return New-SitecBurnInCancelledResult -DurationSeconds $duration -ActualSeconds $elapsed -Reason $reason
            }
            Start-Sleep -Milliseconds 500
        }

        if (-not $proc.HasExited) {
            $elapsed=((Get-Date)-$started).TotalSeconds
            try { & taskkill.exe /PID $proc.Id /T /F | Out-Null } catch { try { $proc.Kill() } catch {} }
            $reason="Burn-in exceeded hard watchdog limit of $watchdogSeconds seconds and its process tree was terminated."
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'TIMEOUT' -Level 'ERROR' -Message $reason -Data ([pscustomobject]@{Pid=$proc.Id;ElapsedSeconds=[math]::Round($elapsed,1);ResultPath=$resultPath;StdOut=$stdoutPath;StdErr=$stderrPath})
            Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 81 -Message 'Burn-in exceeded its hard deadline; stopping workloads and creating diagnostics.'
            return New-SitecBurnInTimeoutResult -DurationSeconds $duration -ActualSeconds $elapsed -Reason $reason
        }

        $exitCode=$proc.ExitCode
        $elapsed=((Get-Date)-$started).TotalSeconds
        if(Test-SitecCancellationRequested -and -not (Test-Path -LiteralPath $resultPath)){
            $reason='Benchmark cancelled by operator.'
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'CANCELLED' -Level 'WARNING' -Message $reason -Data ([pscustomobject]@{ExitCode=$exitCode;ElapsedSeconds=[math]::Round($elapsed,1)})
            return New-SitecBurnInCancelledResult -DurationSeconds $duration -ActualSeconds $elapsed -Reason $reason
        }
        if (Test-Path -LiteralPath $resultPath) {
            try {
                $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status $(if($result.Status -eq 'PASS'){'PASS'}else{'FAIL'}) -Level $(if($result.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("Isolated burn-in child exited with code {0} after {1:N1}s; result={2}." -f $exitCode,$elapsed,$result.Status) -Data ([pscustomobject]@{ExitCode=$exitCode;ElapsedSeconds=[math]::Round($elapsed,1);ResultPath=$resultPath;StdOut=$stdoutPath;StdErr=$stderrPath})
                return $result
            } catch {
                $reason='Burn-in child produced a result file that could not be parsed: '+$_.Exception.Message
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'PARSE_ERROR' -Level 'ERROR' -Message $reason -ErrorRecord $_
                return New-SitecBurnInTimeoutResult -DurationSeconds $duration -ActualSeconds $elapsed -Reason $reason
            }
        }

        $detail=''
        if (Test-Path -LiteralPath $errorPath) {
            try { $detail=(Get-Content -LiteralPath $errorPath -Raw -Encoding UTF8) } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($detail) -and (Test-Path -LiteralPath $stderrPath)) {
            try { $detail=(Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue) } catch {}
        }
        $reason="Burn-in child exited with code $exitCode without a valid result. $detail"
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'ERROR' -Level 'ERROR' -Message $reason -Data ([pscustomobject]@{ExitCode=$exitCode;ErrorPath=$errorPath;StdOut=$stdoutPath;StdErr=$stderrPath})
        return New-SitecBurnInTimeoutResult -DurationSeconds $duration -ActualSeconds $elapsed -Reason $reason
    } catch {
        $elapsed=((Get-Date)-$started).TotalSeconds
        if ($proc -and -not $proc.HasExited) { try { & taskkill.exe /PID $proc.Id /T /F | Out-Null } catch {} }
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Watchdog' -Status 'ERROR' -Level 'ERROR' -Message ('Unable to manage isolated burn-in process: '+$_.Exception.Message) -ErrorRecord $_
        return New-SitecBurnInTimeoutResult -DurationSeconds $duration -ActualSeconds $elapsed -Reason $_.Exception.Message
    }
}
