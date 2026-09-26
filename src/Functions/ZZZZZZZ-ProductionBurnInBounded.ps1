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

    $cpuEnabled=Test-SitecBenchmarkComponent -Name 'CPU'
    $memoryEnabled=Test-SitecBenchmarkComponent -Name 'Memory'
    $diskEnabled=([bool]$cfg.DiskEnabled -and (Test-SitecBenchmarkComponent -Name 'Disk'))
    $graphicsEnabled=([bool]$cfg.GraphicsEnabled -and (Test-SitecBenchmarkComponent -Name 'Graphics'))

    Initialize-SitecBurnInType
    $duration=[math]::Max(30,[int]$cfg.DurationSeconds)
    $cpuPlan=if($cpuEnabled){Get-SitecCpuBurnInPlan -LogicalProcessors ([Environment]::ProcessorCount) -Settings $cfg}else{[pscustomobject]@{CoverageMode='None';LogicalProcessors=[Environment]::ProcessorCount;Threads=0;ThreadCoveragePercent=0;DutyPercent=0;ExpectedPeakPercent=0}}
    $cpuDuty=[int]$cpuPlan.DutyPercent
    $memoryWorkers=[int]$cfg.MemoryWorkers
    $sampleSeconds=[math]::Max([int]$Context.Settings.Sensors.SampleIntervalSeconds,2)
    $finalizeGrace=20
    if ($cfg.PSObject.Properties['FinalizeGraceSeconds']) { $finalizeGrace=[math]::Max(10,[int]$cfg.FinalizeGraceSeconds) }
    $memoryTarget=if($memoryEnabled){Get-SitecBurnInMemoryTarget -Context $Context}else{[pscustomobject]@{CoverageMode='None';AllocationTargetMB=0;TargetPercent=0;ExpectedUsagePercent=0;ReserveMB=0;SafeCoverageTargetMB=0}}
    $graphicsPlan=if($graphicsEnabled){Get-SitecGraphicsBurnInPlan -Settings $cfg}else{[pscustomobject]@{CoverageMode='None';WorkloadMode='None';NormalWindows=0;GlassWindows=0;DesktopWidth=0;DesktopHeight=0;WindowWidth=0;WindowHeight=0;Offscreen=$false;NoLock=$false;TargetAveragePercent=0;TargetPeakPercent=0}}

    $benchDir=Join-Path $RunPath 'benchmark\burnin'
    New-Item -ItemType Directory -Path $benchDir -Force | Out-Null

    $drive=[string]$Context.Settings.DiskSpd.TargetDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive='C:' }
    $diskPlan=[pscustomobject]@{CoverageMode='None';FreeBeforeMB=0;ReserveFreeMB=0;SafeFreeMB=0;TargetSizeMB=0;TargetSizePercentOfFree=0;BlockSizeKB=0;QueueDepth=0;Threads=0;WritePercent=0;CacheMode='None'}
    if($diskEnabled){
        $driveInfo=[System.IO.DriveInfo]::new($drive+'\')
        $freeMB=[long][math]::Floor($driveInfo.AvailableFreeSpace/1MB)
        $diskPlan=Get-SitecDiskBurnInPlan -FreeMB $freeMB -Settings $cfg
    }
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
        $selected=@()
        if($cpuEnabled){$selected+='CPU'};if($memoryEnabled){$selected+='RAM'};if($diskEnabled){$selected+='NVMe'};if($graphicsEnabled){$selected+='Graphics'}
        $coveragePlans=[pscustomobject]@{CPU=$cpuPlan;Memory=$memoryTarget;Disk=$diskPlan;Graphics=$graphicsPlan}
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status 'START' -Message ("Starting {0}s MaximumSafe burn-in for [{1}]; finalization grace {2}s." -f $duration,($selected -join ', '),$finalizeGrace) -Data $coveragePlans

        if ($diskEnabled) {
            $diskExe=Join-Path $Context.ProjectRoot ([string]$Context.Settings.DiskSpd.ExeRelativePath)
            if (Test-Path -LiteralPath $diskExe) {
                New-Item -ItemType Directory -Path $testDir -Force | Out-Null
                $diskTarget=Join-Path $testDir 'diskspd-burnin.dat'
                $size=[int]$diskPlan.TargetSizeMB;$block=[int]$diskPlan.BlockSizeKB;$queue=[int]$diskPlan.QueueDepth;$threads=[int]$diskPlan.Threads
                $args="-c${size}M -b${block}K -r -o$queue -t$threads -W5 -d$duration -C1 -Sh -L -w0 -Rxml `"$diskTarget`""
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status 'START' -Message ("Starting MaximumSafe uncached read-only DiskSpd burn-in: target={0} MB, block={1} KB, queue/thread={2}, threads={3}." -f $size,$block,$queue,$threads) -Data ([pscustomobject]@{Command=$diskExe;Arguments=$args;Plan=$diskPlan})
                $diskProcess=Start-SitecBurnInProcess -FilePath $diskExe -Arguments $args -StdOutPath $diskOut -StdErrPath $diskErr
                $diskStatus='RUNNING'
            } else {
                $diskStatus='DEPENDENCY_MISSING';$diskError='DiskSpd executable not found.'
            }
        }

        $gpuEngine='None'
        if ($graphicsEnabled -and (Get-Command winsat.exe -ErrorAction SilentlyContinue)) {
            if([string]$graphicsPlan.WorkloadMode -eq 'Direct3D-ALU'){
                $gpuEngine='WinSAT Direct3D ALU maximum-load workload'
                $gpuArgs="d3d -aname ALU -time $duration -fbc 10 -disp off -animate 10 -width $($graphicsPlan.DesktopWidth) -height $($graphicsPlan.DesktopHeight) -totalobj 500 -batchcnt C(125) -objs C(20) -noalpha -alushader -totaltex 10 -texpobj C(1) -rendertotex 6 -rtdelta 3"
            } else {
                $gpuEngine='WinSAT DWM composition workload'
                $normal=[int]$graphicsPlan.NormalWindows;$glass=[int]$graphicsPlan.GlassWindows
                $gpuArgs="dwm -normalw $normal -glassw $glass -time $duration -width $($graphicsPlan.DesktopWidth) -height $($graphicsPlan.DesktopHeight) -winwidth $($graphicsPlan.WindowWidth) -winheight $($graphicsPlan.WindowHeight) -v"
                if($graphicsPlan.NoLock){$gpuArgs+=' -nolock'}
                if($graphicsPlan.Offscreen){$gpuArgs+=' -disp off'}else{$gpuArgs+=' -fullscreen'}
            }
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status 'START' -Message ("Starting MaximumSafe GPU workload: {0}; target avg {1}%, target peak {2}%." -f $gpuEngine,$graphicsPlan.TargetAveragePercent,$graphicsPlan.TargetPeakPercent) -Data ([pscustomobject]@{Command='winsat.exe';Arguments=$gpuArgs;Plan=$graphicsPlan;Engine=$gpuEngine})
            $gpuProcess=Start-SitecBurnInProcess -FilePath 'winsat.exe' -Arguments $gpuArgs -StdOutPath $gpuOut -StdErrPath $gpuErr
            $gpuStatus='RUNNING'
        } elseif ($graphicsEnabled) {
            $gpuStatus='UNAVAILABLE';$gpuError='WinSAT unavailable.'
        }

        $started=Get-Date
        $cpuTask=$null;$memoryTask=$null
        if($cpuEnabled){
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'START' -Message ("Starting MaximumSafe CPU worker on {0}/{1} logical processors ({2}% thread coverage) at {3}% duty." -f $cpuPlan.Threads,$cpuPlan.LogicalProcessors,$cpuPlan.ThreadCoveragePercent,$cpuDuty) -Data $cpuPlan
            $cpuTask=[SitecQcBurnInV2]::CpuAsync($duration,[int]$cpuPlan.Threads,$cpuDuty)
        }
        if($memoryEnabled){
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status 'START' -Message ("Starting RAM write/verify: mode={0}; target={1} MB; reserve={2} MB; expected system usage={3}%; workers={4}." -f $memoryTarget.CoverageMode,$memoryTarget.AllocationTargetMB,$memoryTarget.ReserveMB,$memoryTarget.ExpectedUsagePercent,$memoryWorkers) -Data $memoryTarget
            $memoryTask=[SitecQcBurnInV2]::MemoryAsync($duration,[int]$memoryTarget.AllocationTargetMB,$memoryWorkers)
        }

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
            $remaining=[math]::Max(0,$duration-$elapsed)
            Set-SitecBurnInUiProgress -RunPath $RunPath -Percent $uiPercent -ElapsedSeconds $elapsed -RemainingSeconds $remaining -Message ("Concurrent burn-in {0:N0}/{1}s | remaining {2:N0}s | {3}" -f $elapsed,$duration,$remaining,($parts -join ' | '))
            if(Test-SitecCancellationRequested){
                Set-SitecBurnInUiProgress -RunPath $RunPath -Percent $uiPercent -ElapsedSeconds $elapsed -RemainingSeconds 0 -State 'CANCELLING' -Message 'Cancellation requested; stopping benchmark workloads and preserving partial evidence.'
                throw [System.OperationCanceledException]::new('Benchmark cancelled by operator during full-system burn-in.')
            }
            Start-Sleep -Seconds $sampleSeconds
        }

        Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 80 -ElapsedSeconds $duration -RemainingSeconds 0 -Message 'Burn-in duration complete; finalizing workloads and parsing results.'
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Finalize' -Status 'RUNNING' -Message ("Target duration completed. Allowing up to {0}s for workers/tool output to finalize." -f $finalizeGrace)

        $finalDeadline=(Get-Date).AddSeconds($finalizeGrace)
        while ((Get-Date) -lt $finalDeadline) {
            $cpuDone=($null -eq $cpuTask -or $cpuTask.IsCompleted);$memDone=($null -eq $memoryTask -or $memoryTask.IsCompleted)
            $diskDone=(Test-SitecOwnedProcessExited -Process $diskProcess)
            $gpuDone=(Test-SitecOwnedProcessExited -Process $gpuProcess)
            if ($cpuDone -and $memDone -and $diskDone -and $gpuDone) { break }
            Start-Sleep -Milliseconds 250
        }

        $cpu=$null;$memory=$null;$cpuOk=(-not $cpuEnabled);$memoryOk=(-not $memoryEnabled)
        if ($null -ne $cpuTask -and $cpuTask.IsCompleted) {
            try { $cpu=$cpuTask.GetAwaiter().GetResult();$cpuOk=$true } catch { $cpuError=$_.Exception.Message }
        }
        if ($null -ne $memoryTask -and $memoryTask.IsCompleted) {
            try { $memory=$memoryTask.GetAwaiter().GetResult();$memoryOk=($memory.Errors -eq 0 -and $memory.BytesVerified -gt 0 -and $memory.Passes -gt 0 -and $memory.AllocatedMB -ge 128) } catch { $memoryError=$_.Exception.Message }
        }

        if ($cpuEnabled) {
            if ($cpuOk) {
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'PASS' -Message ("CPU completed: {0:N1}s, {1} threads, {2:N0} work units/s." -f $cpu.Seconds,$cpu.Threads,$cpu.WorkUnitsPerSecond) -Data $cpu
            } else {
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'TIMEOUT' -Level 'ERROR' -Message 'CPU worker did not finalize within the bounded window.'
            }
        }
        if ($memoryEnabled) {
            if ($null -ne $memory) {
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status $(if($memoryOk){'PASS'}else{'FAIL'}) -Level $(if($memoryOk){'INFO'}else{'ERROR'}) -Message ("RAM completed: allocated {0} MB, verified {1:N0} MB, passes {2}, errors {3}." -f $memory.AllocatedMB,([double]$memory.BytesVerified/1MB),$memory.Passes,$memory.Errors) -Data $memory
            } else {
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status 'TIMEOUT' -Level 'ERROR' -Message 'RAM worker did not finalize within the bounded window.'
            }
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
            if (($gpuOutput -match 'Total Run Time') -or (($gpuOutput -match 'Direct3D|D3D') -and ($gpuOutput -match 'ALU|Assessment'))) { $gpuEvidence=$true }
            if (($null -ne $gpuExit -and $gpuExit -eq 0) -or $gpuEvidence) { $gpuStatus='PASS' } else { $gpuStatus='FAIL';$gpuError='WinSAT did not produce a completed graphics result.' }
        }

        $tailSensors=@(Get-SitecSensorSnapshot -Context $Context);if($tailSensors.Count -gt 0){$sensorSnapshots += $tailSensors}
        $sensorSummary=@(Get-SitecSensorSummary -Snapshots $sensorSnapshots)
        $utilization=Get-SitecLoadSummary -Samples $loadSamples

        # GPU utilization counters are supporting telemetry, not the workload
        # execution proof. On some Intel iGPU/driver combinations WinSAT D3D
        # completes successfully while Windows reports only 0% GPU counters.
        # Treat that condition as unavailable telemetry rather than a measured
        # zero-load failure; a failed graphics workload still remains blocking.
        $gpuTelemetryStatus=if($graphicsEnabled){'VALID'}else{'NOT_SELECTED'}
        $gpuTelemetryReason=''
        if($graphicsEnabled){
            $gpuSamples=0
            $gpuPeakValue=$null
            if($utilization.GPU -and $utilization.GPU.PSObject.Properties['Samples']){$gpuSamples=[int]$utilization.GPU.Samples}
            if($utilization.GPU -and $null -ne $utilization.GPU.Peak){$gpuPeakValue=[double]$utilization.GPU.Peak}
            if($gpuSamples -le 0 -or $null -eq $gpuPeakValue){
                $gpuTelemetryStatus='UNAVAILABLE'
                $gpuTelemetryReason='Windows GPU utilization counters were unavailable during the graphics workload.'
            } elseif($gpuPeakValue -le 0){
                $gpuTelemetryStatus='UNAVAILABLE'
                $gpuTelemetryReason=$(if($gpuStatus -eq 'PASS'){'Windows GPU utilization counters remained at 0% while the WinSAT graphics workload completed successfully; counter data is unavailable, not a measured 0% load.'}else{'Windows GPU utilization counters remained at 0% during the graphics workload.'})
            }
        }
        if ($null -ne $gpuProcess) {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status $gpuStatus -Level $(if($gpuStatus -eq 'PASS'){'INFO'}else{'WARNING'}) -Message ("Graphics finalized. ExitCode={0}; evidence-complete={1}; forced-stop={2}; GPU peak={3}%; telemetry={4}." -f $gpuExit,$gpuEvidence,$forcedGpuStop,$utilization.GPU.Peak,$gpuTelemetryStatus) -Data ([pscustomobject]@{ExitCode=$gpuExit;EvidenceComplete=$gpuEvidence;ForcedStop=$forcedGpuStop;Output=$gpuOut;Error=$gpuError;TelemetryStatus=$gpuTelemetryStatus;TelemetryReason=$gpuTelemetryReason})
        }

        $requiredDisk=$diskEnabled;$requiredGraphics=($graphicsEnabled -and [bool]$cfg.GraphicsRequired)
        $pass=$cpuOk -and $memoryOk
        if ($requiredDisk -and $diskStatus -ne 'PASS') { $pass=$false }
        if ($requiredGraphics -and $gpuStatus -ne 'PASS') { $pass=$false }
        $finished=Get-Date

        $cpuResult=if($cpu){[pscustomobject]@{Enabled=$true;Status='PASS';CoverageMode=$cpuPlan.CoverageMode;Seconds=[math]::Round($cpu.Seconds,1);LogicalProcessors=$cpuPlan.LogicalProcessors;Threads=$cpu.Threads;ThreadCoveragePercent=[math]::Round(($cpu.Threads/[double]$cpuPlan.LogicalProcessors)*100,1);DutyPercent=$cpu.DutyPercent;HashWorkMBps=[math]::Round($cpu.WorkUnitsPerSecond,2);WorkUnitsPerSecond=[math]::Round($cpu.WorkUnitsPerSecond,2);Iterations=$cpu.Iterations}}elseif($cpuEnabled){[pscustomobject]@{Enabled=$true;Status='FAIL';CoverageMode=$cpuPlan.CoverageMode;Seconds=0;LogicalProcessors=$cpuPlan.LogicalProcessors;Threads=$cpuPlan.Threads;ThreadCoveragePercent=$cpuPlan.ThreadCoveragePercent;DutyPercent=$cpuDuty;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0}}else{[pscustomobject]@{Enabled=$false;Status='SKIPPED';CoverageMode='None';Seconds=0;LogicalProcessors=[Environment]::ProcessorCount;Threads=0;ThreadCoveragePercent=0;DutyPercent=0;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0}}
        $memoryCoveragePercent=0.0
        if($memoryEnabled -and $memory -and [double]$memoryTarget.SafeCoverageTargetMB -gt 0){
            $memoryCoveragePercent=[math]::Round(([double]$memory.AllocatedMB/[double]$memoryTarget.SafeCoverageTargetMB)*100,1)
        }
        $memResult=if($memory){[pscustomobject]@{Enabled=$true;Status=$(if($memoryOk){'PASS'}else{'FAIL'});RequestedMB=$memory.RequestedMB;AllocatedMB=$memory.AllocatedMB;VerifiedMB=[math]::Round([double]$memory.BytesVerified/1MB,0);Errors=$memory.Errors;Seconds=[math]::Round($memory.Seconds,1);Passes=$memory.Passes;CoverageMode=$memoryTarget.CoverageMode;TargetSystemUsagePercent=$memoryTarget.TargetPercent;ExpectedSystemUsagePercent=$memoryTarget.ExpectedUsagePercent;AllocationMode=$memoryTarget.MaximumMode;SafeCoverageTargetMB=$memoryTarget.SafeCoverageTargetMB;AllocationCoveragePercent=$memoryCoveragePercent;ReserveMB=$memoryTarget.ReserveMB}}elseif($memoryEnabled){[pscustomobject]@{Enabled=$true;Status='FAIL';RequestedMB=$memoryTarget.AllocationTargetMB;AllocatedMB=0;VerifiedMB=0;Errors=[long]::MaxValue;Seconds=0;Passes=0;CoverageMode=$memoryTarget.CoverageMode;TargetSystemUsagePercent=$memoryTarget.TargetPercent;ExpectedSystemUsagePercent=$memoryTarget.ExpectedUsagePercent;AllocationMode=$memoryTarget.MaximumMode;SafeCoverageTargetMB=$memoryTarget.SafeCoverageTargetMB;AllocationCoveragePercent=0;ReserveMB=$memoryTarget.ReserveMB}}else{[pscustomobject]@{Enabled=$false;Status='SKIPPED';RequestedMB=0;AllocatedMB=0;VerifiedMB=0;Errors=0;Seconds=0;Passes=0;CoverageMode='None';TargetSystemUsagePercent=$null;ExpectedSystemUsagePercent=$null;AllocationMode='None';SafeCoverageTargetMB=0;AllocationCoveragePercent=0;ReserveMB=0}}

        $result=[pscustomobject]@{
            Status=if($pass){'PASS'}else{'FAIL'};Required=$true;TimedOut=$false;Error='';StartedAt=$started.ToString('o');FinishedAt=$finished.ToString('o');DurationSeconds=$duration;ActualSeconds=[math]::Round(($finished-$started).TotalSeconds,1)
            Selection=@($selected)
            CpuStress=$cpuResult;MemoryVerification=$memResult
            DiskStress=[pscustomobject]@{Enabled=$diskEnabled;Status=$diskStatus;CoverageMode=$diskPlan.CoverageMode;ProcessExitCode=$diskExit;ReadMBps=$(if($diskMetrics){$diskMetrics.ReadMBps}else{$null});ReadIOPS=$(if($diskMetrics){$diskMetrics.ReadIOPS}else{$null});AverageReadLatencyMs=$(if($diskMetrics){$diskMetrics.AverageReadLatencyMs}else{$null});TargetSizeMB=$diskPlan.TargetSizeMB;FreeBeforeMB=$diskPlan.FreeBeforeMB;ReserveFreeMB=$diskPlan.ReserveFreeMB;BlockSizeKB=$diskPlan.BlockSizeKB;QueueDepth=$diskPlan.QueueDepth;Threads=$diskPlan.Threads;WritePercent=0;CacheMode=$diskPlan.CacheMode;ForcedStop=$forcedDiskStop;Error=$diskError;XmlPath=$diskOut;StdErrPath=$diskErr}
            GraphicsStress=[pscustomobject]@{Enabled=$graphicsEnabled;Required=$requiredGraphics;Status=$gpuStatus;TelemetryStatus=$gpuTelemetryStatus;TelemetryReason=$gpuTelemetryReason;CoverageMode=$graphicsPlan.CoverageMode;WorkloadMode=$graphicsPlan.WorkloadMode;TargetAveragePercent=$graphicsPlan.TargetAveragePercent;TargetPeakPercent=$graphicsPlan.TargetPeakPercent;NormalWindows=$graphicsPlan.NormalWindows;GlassWindows=$graphicsPlan.GlassWindows;Resolution=("$($graphicsPlan.DesktopWidth)x$($graphicsPlan.DesktopHeight)");Offscreen=$graphicsPlan.Offscreen;NoLock=$graphicsPlan.NoLock;ProcessExitCode=$gpuExit;Engine=$gpuEngine;ForcedStop=$forcedGpuStop;Error=$gpuError;OutputPath=$gpuOut;StdErrPath=$gpuErr}
            Utilization=$utilization;Sensors=$sensorSummary;LoadSamples=@($loadSamples)
        }
        Write-SitecStepResult -RunPath $RunPath -Step '40-full-system-burnin' -Value $result | Out-Null
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status $result.Status -Level $(if($result.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("Bounded burn-in completed in {0:N1}s: status={1}; CPU avg={2}%; RAM peak={3}%; Disk={4}; Graphics={5}." -f $result.ActualSeconds,$result.Status,$utilization.CPU.Average,$utilization.Memory.Peak,$diskStatus,$gpuStatus) -Data $result
        return $result
    }
    finally {
        Stop-SitecOwnedProcessTree -Process $diskProcess
        Stop-SitecOwnedProcessTree -Process $gpuProcess
        if($diskEnabled){Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
