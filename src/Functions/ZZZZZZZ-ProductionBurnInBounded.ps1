# Production burn-in finalization fix.
# Loaded after ZZZZZZZ-BurnInRuntimeFixes.ps1 and before the watchdog wrapper.
# The target duration is authoritative: external tool processes get a short bounded
# finalization window and are never allowed to hold the whole QC pipeline open.

function Test-SitecOwnedProcessExited {
    param($Process)
    if ($null -eq $Process) { return $true }
    try {
        $Process.Refresh()
        return [bool]$Process.WaitForExit(0)
    } catch {
        try { return [bool]$Process.HasExited } catch { return $true }
    }
}

function Stop-SitecOwnedProcessTree {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not (Test-SitecOwnedProcessExited -Process $Process)) {
            & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
        }
    } catch {
        try { $Process.Kill() } catch {}
    }
}

function Invoke-SitecFullSystemBurnIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)

    $cfg=$Context.Settings.BurnIn
    if ($null -eq $cfg -or -not [bool]$cfg.Enabled) {
        return [pscustomobject]@{Status='SKIPPED';Required=$false;DurationSeconds=0;Sensors=@();Utilization=(Get-SitecLoadSummary @())}
    }

    Initialize-SitecBurnInType
    $duration=[math]::Max(30,[int]$cfg.DurationSeconds)
    $cpuDuty=[int]$cfg.CpuDutyPercent
    $memoryWorkers=[int]$cfg.MemoryWorkers
    $sampleSeconds=[math]::Max([int]$Context.Settings.Sensors.SampleIntervalSeconds,2)
    $finalizeGrace=20
    if ($cfg.PSObject.Properties['FinalizeGraceSeconds']) { $finalizeGrace=[math]::Max(10,[int]$cfg.FinalizeGraceSeconds) }
    $memoryTarget=Get-SitecBurnInMemoryTarget -Context $Context

    $benchDir=Join-Path $RunPath 'benchmark\burnin'
    New-Item -ItemType Directory -Path $benchDir -Force | Out-Null

    $drive=[string]$Context.Settings.DiskSpd.TargetDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive='C:' }
    $testDir=Join-Path ($drive+'\') 'SitecQC-Temp'
    # This directory belongs exclusively to SitecQC. Remove leftovers from interrupted runs.
    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue

    $diskProcess=$null;$gpuProcess=$null;$diskTarget=$null;$diskMetrics=$null
    $diskStatus='SKIPPED';$gpuStatus='SKIPPED';$diskExit=$null;$gpuExit=$null
    $diskError='';$gpuError='';$forcedGpuStop=$false;$forcedDiskStop=$false
    $diskOut=Join-Path $benchDir 'disk-burnin.xml'
    $diskErr=Join-Path $benchDir 'disk-burnin.err.txt'
    $gpuOut=Join-Path $benchDir 'graphics-burnin.out.txt'
    $gpuErr=Join-Path $benchDir 'graphics-burnin.err.txt'

    try {
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status 'START' -Message ("Starting {0}s bounded concurrent burn-in; finalization grace {1}s." -f $duration,$finalizeGrace) -Data $memoryTarget

        if ([bool]$cfg.DiskEnabled) {
            $diskExe=Join-Path $Context.ProjectRoot ([string]$Context.Settings.DiskSpd.ExeRelativePath)
            if (Test-Path -LiteralPath $diskExe) {
                New-Item -ItemType Directory -Path $testDir -Force | Out-Null
                $diskTarget=Join-Path $testDir 'diskspd-burnin.dat'
                $size=[int]$cfg.DiskTargetSizeMB;$block=[int]$cfg.DiskBlockSizeKB;$queue=[int]$cfg.DiskQueueDepth;$threads=[int]$cfg.DiskThreads
                $args="-c${size}M -b${block}K -r -o$queue -t$threads -W5 -d$duration -C1 -Sh -L -w0 -Rxml `"$diskTarget`""
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status 'START' -Message 'Starting sustained read-only DiskSpd burn-in.' -Data ([pscustomobject]@{Command=$diskExe;Arguments=$args})
                $diskProcess=Start-SitecBurnInProcess -FilePath $diskExe -Arguments $args -StdOutPath $diskOut -StdErrPath $diskErr
                $diskStatus='RUNNING'
            } else {
                $diskStatus='DEPENDENCY_MISSING';$diskError='DiskSpd executable not found.'
            }
        }

        if ([bool]$cfg.GraphicsEnabled -and (Get-Command winsat.exe -ErrorAction SilentlyContinue)) {
            $normal=[int]$cfg.GraphicsNormalWindows;$glass=[int]$cfg.GraphicsGlassWindows
            $gpuArgs="dwm -normalw $normal -glassw $glass -time $duration -v -fullscreen"
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status 'START' -Message 'Starting WinSAT DWM graphics workload.' -Data ([pscustomobject]@{Command='winsat.exe';Arguments=$gpuArgs})
            $gpuProcess=Start-SitecBurnInProcess -FilePath 'winsat.exe' -Arguments $gpuArgs -StdOutPath $gpuOut -StdErrPath $gpuErr
            $gpuStatus='RUNNING'
        } elseif ([bool]$cfg.GraphicsEnabled) {
            $gpuStatus='UNAVAILABLE';$gpuError='WinSAT unavailable.'
        }

        $started=Get-Date
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'START' -Message ("Starting CPU worker on {0} logical processors at {1}% duty." -f [Environment]::ProcessorCount,$cpuDuty)
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status 'START' -Message ("Starting RAM write/verify: target {0} MB with {1} workers." -f $memoryTarget.AllocationTargetMB,$memoryWorkers)
        $cpuTask=[SitecQcBurnInV2]::CpuAsync($duration,[Environment]::ProcessorCount,$cpuDuty)
        $memoryTask=[SitecQcBurnInV2]::MemoryAsync($duration,[int]$memoryTarget.AllocationTargetMB,$memoryWorkers)

        $loadSamples=@();$sensorSnapshots=@();$lastMinute=-1
        $targetEnd=$started.AddSeconds($duration)
        while ((Get-Date) -lt $targetEnd) {
            $sample=Get-SitecLoadSnapshot
            $loadSamples += $sample
            $sensors=@(Get-SitecSensorSnapshot -Context $Context)
            if ($sensors.Count -gt 0) { $sensorSnapshots += $sensors }
            $elapsed=[math]::Min($duration,[math]::Max(0,((Get-Date)-$started).TotalSeconds))
            $minute=[int][math]::Floor($elapsed/60)
            if ($minute -ne $lastMinute) {
                $lastMinute=$minute
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Telemetry' -Status 'RUNNING' -Message ("Elapsed {0:N0}s: CPU {1}%, RAM {2}%, Disk {3}%, GPU {4}%." -f $elapsed,$sample.CpuPercent,$sample.MemoryUsedPercent,$sample.DiskActivePercent,$sample.GpuEnginePercent) -Data $sample
            }
            $ratio=$elapsed/[double]$duration;$uiPercent=40+[int][math]::Floor($ratio*40)
            $parts=@()
            if ($null -ne $sample.CpuPercent) { $parts += ('CPU {0:N0}%' -f $sample.CpuPercent) }
            if ($null -ne $sample.MemoryUsedPercent) { $parts += ('RAM {0:N0}%' -f $sample.MemoryUsedPercent) }
            if ($null -ne $sample.DiskActivePercent) { $parts += ('Disk {0:N0}%' -f $sample.DiskActivePercent) }
            if ($null -ne $sample.GpuEnginePercent) { $parts += ('GPU {0:N0}%' -f $sample.GpuEnginePercent) }
            Set-SitecBurnInUiProgress -RunPath $RunPath -Percent $uiPercent -Message ("Concurrent burn-in {0:N0}/{1}s | {2}" -f $elapsed,$duration,($parts -join ' | '))
            Start-Sleep -Seconds $sampleSeconds
        }

        Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 80 -Message 'Burn-in duration complete; finalizing workloads and parsing results.'
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Finalize' -Status 'RUNNING' -Message ("Target duration completed. Allowing up to {0}s for workers/tool output to finalize." -f $finalizeGrace)

        $finalDeadline=(Get-Date).AddSeconds($finalizeGrace)
        while ((Get-Date) -lt $finalDeadline) {
            $cpuDone=$cpuTask.IsCompleted;$memDone=$memoryTask.IsCompleted
            $diskDone=(Test-SitecOwnedProcessExited -Process $diskProcess)
            $gpuDone=(Test-SitecOwnedProcessExited -Process $gpuProcess)
            if ($cpuDone -and $memDone -and $diskDone -and $gpuDone) { break }
            Start-Sleep -Milliseconds 250
        }

        $cpu=$null;$memory=$null;$cpuOk=$false;$memoryOk=$false
        if ($cpuTask.IsCompleted) {
            try { $cpu=$cpuTask.GetAwaiter().GetResult();$cpuOk=$true } catch { $cpuError=$_.Exception.Message }
        }
        if ($memoryTask.IsCompleted) {
            try { $memory=$memoryTask.GetAwaiter().GetResult();$memoryOk=($memory.Errors -eq 0) } catch { $memoryError=$_.Exception.Message }
        }

        if ($cpuOk) {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'PASS' -Message ("CPU completed: {0:N1}s, {1} threads, {2:N0} work units/s." -f $cpu.Seconds,$cpu.Threads,$cpu.WorkUnitsPerSecond) -Data $cpu
        } else {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'TIMEOUT' -Level 'ERROR' -Message 'CPU worker did not finalize within the bounded window.'
        }
        if ($null -ne $memory) {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status $(if($memoryOk){'PASS'}else{'FAIL'}) -Level $(if($memoryOk){'INFO'}else{'ERROR'}) -Message ("RAM completed: allocated {0} MB, verified {1:N0} MB, passes {2}, errors {3}." -f $memory.AllocatedMB,([double]$memory.BytesVerified/1MB),$memory.Passes,$memory.Errors) -Data $memory
        } else {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status 'TIMEOUT' -Level 'ERROR' -Message 'RAM worker did not finalize within the bounded window.'
        }

        if ($null -ne $diskProcess) {
            $diskExited=Test-SitecOwnedProcessExited -Process $diskProcess
            if (-not $diskExited) { $forcedDiskStop=$true;Stop-SitecOwnedProcessTree -Process $diskProcess }
            try { if (Test-SitecOwnedProcessExited -Process $diskProcess) { $diskExit=$diskProcess.ExitCode } } catch {}
            if (Test-Path -LiteralPath $diskOut) {
                try {
                    $diskMetrics=Get-SitecDiskSpdMetrics -XmlPath $diskOut
                    if ($diskMetrics -and [double]$diskMetrics.ReadMBps -gt 0) { $diskStatus='PASS' } else { $diskStatus='FAIL' }
                } catch { $diskStatus='FAIL';$diskError=$_.Exception.Message }
            } else { $diskStatus='FAIL';$diskError='DiskSpd result XML was not created.' }
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status $diskStatus -Level $(if($diskStatus -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("NVMe finalized. Read={0} MB/s; IOPS={1}; forced-stop={2}." -f $diskMetrics.ReadMBps,$diskMetrics.ReadIOPS,$forcedDiskStop) -Data ([pscustomobject]@{ExitCode=$diskExit;ForcedStop=$forcedDiskStop;Metrics=$diskMetrics;Error=$diskError})
        }

        if ($null -ne $gpuProcess) {
            $gpuExited=Test-SitecOwnedProcessExited -Process $gpuProcess
            if (-not $gpuExited) { $forcedGpuStop=$true;Stop-SitecOwnedProcessTree -Process $gpuProcess }
            try { if (Test-SitecOwnedProcessExited -Process $gpuProcess) { $gpuExit=$gpuProcess.ExitCode } } catch {}
            $gpuOutput='';$gpuEvidence=$false
            try { if (Test-Path -LiteralPath $gpuOut) { $gpuOutput=Get-Content -LiteralPath $gpuOut -Raw -ErrorAction SilentlyContinue } } catch {}
            if ($gpuOutput -match 'Total Run Time' -and $gpuOutput -match 'Video Memory Throughput') { $gpuEvidence=$true }
            if (($null -ne $gpuExit -and $gpuExit -eq 0) -or $gpuEvidence) { $gpuStatus='PASS' } else { $gpuStatus='FAIL';$gpuError='WinSAT did not produce a completed graphics result.' }
        }

        $tailSensors=@(Get-SitecSensorSnapshot -Context $Context);if($tailSensors.Count -gt 0){$sensorSnapshots += $tailSensors}
        $sensorSummary=@(Get-SitecSensorSummary -Snapshots $sensorSnapshots)
        $utilization=Get-SitecLoadSummary -Samples $loadSamples
        if ($null -ne $gpuProcess) {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status $gpuStatus -Level $(if($gpuStatus -eq 'PASS'){'INFO'}else{'WARNING'}) -Message ("Graphics finalized. ExitCode={0}; evidence-complete={1}; forced-stop={2}; GPU peak={3}%." -f $gpuExit,$gpuEvidence,$forcedGpuStop,$utilization.GPU.Peak) -Data ([pscustomobject]@{ExitCode=$gpuExit;EvidenceComplete=$gpuEvidence;ForcedStop=$forcedGpuStop;Output=$gpuOut;Error=$gpuError})
        }

        $requiredDisk=[bool]$cfg.DiskEnabled;$requiredGraphics=[bool]$cfg.GraphicsRequired
        $pass=$cpuOk -and $memoryOk
        if ($requiredDisk -and $diskStatus -ne 'PASS') { $pass=$false }
        if ($requiredGraphics -and $gpuStatus -ne 'PASS') { $pass=$false }
        $finished=Get-Date

        $cpuResult=if($cpu){[pscustomobject]@{Seconds=[math]::Round($cpu.Seconds,1);Threads=$cpu.Threads;DutyPercent=$cpu.DutyPercent;HashWorkMBps=[math]::Round($cpu.WorkUnitsPerSecond,2);WorkUnitsPerSecond=[math]::Round($cpu.WorkUnitsPerSecond,2);Iterations=$cpu.Iterations}}else{[pscustomobject]@{Seconds=0;Threads=[Environment]::ProcessorCount;DutyPercent=$cpuDuty;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0}}
        $memResult=if($memory){[pscustomobject]@{RequestedMB=$memory.RequestedMB;AllocatedMB=$memory.AllocatedMB;VerifiedMB=[math]::Round([double]$memory.BytesVerified/1MB,0);Errors=$memory.Errors;Seconds=[math]::Round($memory.Seconds,1);Passes=$memory.Passes;TargetSystemUsagePercent=$memoryTarget.TargetPercent}}else{[pscustomobject]@{RequestedMB=$memoryTarget.AllocationTargetMB;AllocatedMB=0;VerifiedMB=0;Errors=[long]::MaxValue;Seconds=0;Passes=0;TargetSystemUsagePercent=$memoryTarget.TargetPercent}}

        $result=[pscustomobject]@{
            Status=if($pass){'PASS'}else{'FAIL'};Required=$true;TimedOut=$false;Error='';StartedAt=$started.ToString('o');FinishedAt=$finished.ToString('o');DurationSeconds=$duration;ActualSeconds=[math]::Round(($finished-$started).TotalSeconds,1)
            CpuStress=$cpuResult;MemoryVerification=$memResult
            DiskStress=[pscustomobject]@{Enabled=[bool]$cfg.DiskEnabled;Status=$diskStatus;ProcessExitCode=$diskExit;ReadMBps=$(if($diskMetrics){$diskMetrics.ReadMBps}else{$null});ReadIOPS=$(if($diskMetrics){$diskMetrics.ReadIOPS}else{$null});AverageReadLatencyMs=$(if($diskMetrics){$diskMetrics.AverageReadLatencyMs}else{$null});BlockSizeKB=[int]$cfg.DiskBlockSizeKB;QueueDepth=[int]$cfg.DiskQueueDepth;Threads=[int]$cfg.DiskThreads;WritePercent=0;ForcedStop=$forcedDiskStop;Error=$diskError;XmlPath=$diskOut;StdErrPath=$diskErr}
            GraphicsStress=[pscustomobject]@{Enabled=[bool]$cfg.GraphicsEnabled;Required=$requiredGraphics;Status=$gpuStatus;ProcessExitCode=$gpuExit;Engine='WinSAT DWM composition workload';ForcedStop=$forcedGpuStop;Error=$gpuError;OutputPath=$gpuOut;StdErrPath=$gpuErr}
            Utilization=$utilization;Sensors=$sensorSummary;LoadSamples=@($loadSamples)
        }
        Write-SitecStepResult -RunPath $RunPath -Step '40-full-system-burnin' -Value $result | Out-Null
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status $result.Status -Level $(if($result.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("Bounded burn-in completed in {0:N1}s: status={1}; CPU avg={2}%; RAM peak={3}%; Disk={4}; Graphics={5}." -f $result.ActualSeconds,$result.Status,$utilization.CPU.Average,$utilization.Memory.Peak,$diskStatus,$gpuStatus) -Data $result
        return $result
    }
    finally {
        Stop-SitecOwnedProcessTree -Process $diskProcess
        Stop-SitecOwnedProcessTree -Process $gpuProcess
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
