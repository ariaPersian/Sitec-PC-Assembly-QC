# Runtime fixes derived from the first 15-minute production soak.
# This override keeps the v4 data contract while adding deterministic diagnostics,
# robust DiskSpd completion handling, and a documented WinSAT DWM invocation.

function Invoke-SitecFullSystemBurnIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)

    $cfg=$Context.Settings.BurnIn
    if ($null -eq $cfg -or -not [bool]$cfg.Enabled) {
        return [pscustomobject]@{Status='SKIPPED';Required=$false;DurationSeconds=0;Sensors=@();Utilization=(Get-SitecLoadSummary @())}
    }

    Initialize-SitecBurnInType
    $duration=[int]$cfg.DurationSeconds
    if ($duration -lt 30) { $duration=30 }
    $cpuDuty=[int]$cfg.CpuDutyPercent
    $memoryWorkers=[int]$cfg.MemoryWorkers
    $sampleSeconds=[math]::Max([int]$Context.Settings.Sensors.SampleIntervalSeconds,2)
    $memoryTarget=Get-SitecBurnInMemoryTarget -Context $Context
    $benchDir=Join-Path $RunPath 'benchmark\burnin'
    New-Item -ItemType Directory -Path $benchDir -Force | Out-Null

    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status 'START' -Message ("Starting {0}s concurrent burn-in: CPU duty {1}%, RAM target {2}%, NVMe and graphics." -f $duration,$cpuDuty,$memoryTarget.TargetPercent) -Data $memoryTarget

    $diskProcess=$null;$gpuProcess=$null
    $diskStatus='SKIPPED';$gpuStatus='SKIPPED';$diskMetrics=$null;$diskTarget=$null
    $diskExit=$null;$gpuExit=$null;$diskParseError='';$gpuError=''
    $diskOut=Join-Path $benchDir 'disk-burnin.xml'
    $diskErr=Join-Path $benchDir 'disk-burnin.err.txt'
    $gpuOut=Join-Path $benchDir 'graphics-burnin.out.txt'
    $gpuErr=Join-Path $benchDir 'graphics-burnin.err.txt'

    if ([bool]$cfg.DiskEnabled) {
        $diskExe=Join-Path $Context.ProjectRoot ([string]$Context.Settings.DiskSpd.ExeRelativePath)
        if (Test-Path -LiteralPath $diskExe) {
            $drive=[string]$Context.Settings.DiskSpd.TargetDrive
            if ([string]::IsNullOrWhiteSpace($drive)) { $drive='C:' }
            $testDir=Join-Path ($drive+'\') 'SitecQC-Temp'
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $diskTarget=Join-Path $testDir 'diskspd-burnin.dat'
            $size=[int]$cfg.DiskTargetSizeMB;$block=[int]$cfg.DiskBlockSizeKB;$queue=[int]$cfg.DiskQueueDepth;$threads=[int]$cfg.DiskThreads
            $args="-c${size}M -b${block}K -r -o$queue -t$threads -W5 -d$duration -C1 -Sh -L -w0 -Rxml `"$diskTarget`""
            try {
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status 'START' -Message 'Starting sustained read-only DiskSpd burn-in.' -Data ([pscustomobject]@{Command=$diskExe;Arguments=$args;Output=$diskOut;ErrorOutput=$diskErr})
                $diskProcess=Start-SitecBurnInProcess -FilePath $diskExe -Arguments $args -StdOutPath $diskOut -StdErrPath $diskErr
                $diskStatus='RUNNING'
            } catch {
                $diskStatus='FAIL';$diskParseError=$_.Exception.Message
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status 'ERROR' -Level 'ERROR' -Message ('Unable to start DiskSpd: '+$_.Exception.Message) -ErrorRecord $_
            }
        } else {
            $diskStatus='DEPENDENCY_MISSING'
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status 'DEPENDENCY_MISSING' -Level 'ERROR' -Message ('DiskSpd not found: '+$diskExe)
        }
    }

    if ([bool]$cfg.GraphicsEnabled -and (Get-Command winsat.exe -ErrorAction SilentlyContinue)) {
        $normal=[int]$cfg.GraphicsNormalWindows;$glass=[int]$cfg.GraphicsGlassWindows
        # Use Microsoft-documented DWM parameters only. Plain -winwidth/-winheight values
        # are distributions in WinSAT and caused the production error "Unable to create distribution".
        $gpuArgs="dwm -normalw $normal -glassw $glass -time $duration -v -fullscreen"
        try {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status 'START' -Message 'Starting WinSAT DWM graphics workload.' -Data ([pscustomobject]@{Command='winsat.exe';Arguments=$gpuArgs;Output=$gpuOut;ErrorOutput=$gpuErr})
            $gpuProcess=Start-SitecBurnInProcess -FilePath 'winsat.exe' -Arguments $gpuArgs -StdOutPath $gpuOut -StdErrPath $gpuErr
            $gpuStatus='RUNNING'
        } catch {
            $gpuStatus='FAIL';$gpuError=$_.Exception.Message
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status 'ERROR' -Level 'WARNING' -Message ('Unable to start graphics workload: '+$_.Exception.Message) -ErrorRecord $_
        }
    } elseif ([bool]$cfg.GraphicsEnabled) {
        $gpuStatus='UNAVAILABLE'
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status 'UNAVAILABLE' -Level 'WARNING' -Message 'WinSAT is unavailable.'
    }

    $started=Get-Date
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'START' -Message ("Starting CPU worker on {0} logical processors at {1}% duty." -f [Environment]::ProcessorCount,$cpuDuty)
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status 'START' -Message ("Starting RAM write/verify: target allocation {0} MB with {1} workers." -f $memoryTarget.AllocationTargetMB,$memoryWorkers)
    $cpuTask=[SitecQcBurnInV2]::CpuAsync($duration,[Environment]::ProcessorCount,$cpuDuty)
    $memoryTask=[SitecQcBurnInV2]::MemoryAsync($duration,[int]$memoryTarget.AllocationTargetMB,$memoryWorkers)

    $loadSamples=@();$sensorSnapshots=@();$hardDeadline=$started.AddSeconds($duration+60);$lastMinute=-1
    while ($true) {
        $cpuDone=$cpuTask.IsCompleted;$memDone=$memoryTask.IsCompleted
        $diskDone=($null -eq $diskProcess -or $diskProcess.HasExited)
        $gpuDone=($null -eq $gpuProcess -or $gpuProcess.HasExited)
        if ($cpuDone -and $memDone -and $diskDone -and $gpuDone) { break }
        if ((Get-Date) -gt $hardDeadline) {
            Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status 'TIMEOUT' -Level 'ERROR' -Message 'Burn-in exceeded its hard completion deadline.'
            break
        }

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
        $loadText=@()
        if ($null -ne $sample.CpuPercent) { $loadText += ('CPU {0:N0}%' -f $sample.CpuPercent) }
        if ($null -ne $sample.MemoryUsedPercent) { $loadText += ('RAM {0:N0}%' -f $sample.MemoryUsedPercent) }
        if ($null -ne $sample.DiskActivePercent) { $loadText += ('Disk {0:N0}%' -f $sample.DiskActivePercent) }
        if ($null -ne $sample.GpuEnginePercent) { $loadText += ('GPU {0:N0}%' -f $sample.GpuEnginePercent) }
        Set-SitecBurnInUiProgress -RunPath $RunPath -Percent $uiPercent -Message ("Concurrent burn-in {0:N0}/{1}s | {2}" -f $elapsed,$duration,($loadText -join ' | '))
        Start-Sleep -Seconds $sampleSeconds
    }

    if (-not $cpuTask.IsCompleted -or -not $memoryTask.IsCompleted) { throw 'CPU/RAM burn-in exceeded the allowed completion window.' }
    $cpu=$cpuTask.GetAwaiter().GetResult();$memory=$memoryTask.GetAwaiter().GetResult()
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'CPU' -Status 'PASS' -Message ("CPU worker completed: {0:N1}s, {1} threads, {2} work units/s." -f $cpu.Seconds,$cpu.Threads,$cpu.WorkUnitsPerSecond) -Data $cpu
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Memory' -Status $(if($memory.Errors -eq 0){'PASS'}else{'FAIL'}) -Level $(if($memory.Errors -eq 0){'INFO'}else{'ERROR'}) -Message ("RAM completed: allocated {0} MB, verified {1:N0} MB, passes {2}, errors {3}." -f $memory.AllocatedMB,([double]$memory.BytesVerified/1MB),$memory.Passes,$memory.Errors) -Data $memory

    if ($null -ne $diskProcess) {
        if (-not $diskProcess.HasExited) { try { $diskProcess.Kill() } catch {} }
        try { if ($diskProcess.HasExited) { $diskExit=$diskProcess.ExitCode } } catch {}
        # A complete, parseable Results XML is the authoritative success artifact. This avoids
        # false FAILs observed when the asynchronous process wrapper did not preserve ExitCode reliably.
        if (Test-Path -LiteralPath $diskOut) {
            try {
                $diskMetrics=Get-SitecDiskSpdMetrics -XmlPath $diskOut
                if ($null -ne $diskMetrics -and [double]$diskMetrics.ReadMBps -gt 0) { $diskStatus='PASS' } else { $diskStatus='FAIL' }
            } catch {
                $diskStatus='FAIL';$diskParseError=$_.Exception.Message
                Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status 'PARSE_ERROR' -Level 'ERROR' -Message ('DiskSpd result XML could not be parsed: '+$_.Exception.Message) -ErrorRecord $_
            }
        } else {
            $diskStatus='FAIL';$diskParseError='DiskSpd result XML was not created.'
        }
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'NVMe' -Status $diskStatus -Level $(if($diskStatus -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("NVMe burn-in completed. ExitCode={0}; Read={1} MB/s; IOPS={2}; Latency={3} ms." -f $diskExit,$diskMetrics.ReadMBps,$diskMetrics.ReadIOPS,$diskMetrics.AverageReadLatencyMs) -Data ([pscustomobject]@{ExitCode=$diskExit;Metrics=$diskMetrics;ParseError=$diskParseError;Xml=$diskOut;StdErr=$diskErr})
    }

    if ($null -ne $gpuProcess) {
        if (-not $gpuProcess.HasExited) { try { $gpuProcess.Kill() } catch {} }
        try { if ($gpuProcess.HasExited) { $gpuExit=$gpuProcess.ExitCode } } catch {}
        if ($gpuExit -eq 0) { $gpuStatus='PASS' } else {
            $gpuStatus='FAIL'
            try { if (Test-Path -LiteralPath $gpuErr) { $gpuError=(Get-Content -LiteralPath $gpuErr -Raw -ErrorAction SilentlyContinue) } } catch {}
        }
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'Graphics' -Status $gpuStatus -Level $(if($gpuStatus -eq 'PASS'){'INFO'}else{'WARNING'}) -Message ("Graphics workload completed. ExitCode={0}." -f $gpuExit) -Data ([pscustomobject]@{ExitCode=$gpuExit;Output=$gpuOut;StdErr=$gpuErr;Error=$gpuError})
    }

    if ($diskTarget) {
        Remove-Item -LiteralPath $diskTarget -Force -ErrorAction SilentlyContinue
        $parent=Split-Path -Parent $diskTarget
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }

    $tailSensors=@(Get-SitecSensorSnapshot -Context $Context);if($tailSensors.Count -gt 0){$sensorSnapshots += $tailSensors}
    $sensorSummary=@(Get-SitecSensorSummary -Snapshots $sensorSnapshots)
    $utilization=Get-SitecLoadSummary -Samples $loadSamples
    $finished=Get-Date
    $requiredDisk=[bool]$cfg.DiskEnabled;$requiredGraphics=[bool]$cfg.GraphicsRequired
    $pass=($memory.Errors -eq 0)
    if ($requiredDisk -and $diskStatus -ne 'PASS') { $pass=$false }
    if ($requiredGraphics -and $gpuStatus -ne 'PASS') { $pass=$false }

    $result=[pscustomobject]@{
        Status=if($pass){'PASS'}else{'FAIL'};Required=$true;StartedAt=$started.ToString('o');FinishedAt=$finished.ToString('o');DurationSeconds=$duration;ActualSeconds=[math]::Round(($finished-$started).TotalSeconds,1)
        CpuStress=[pscustomobject]@{Seconds=[math]::Round($cpu.Seconds,1);Threads=$cpu.Threads;DutyPercent=$cpu.DutyPercent;HashWorkMBps=[math]::Round($cpu.WorkUnitsPerSecond,2);WorkUnitsPerSecond=[math]::Round($cpu.WorkUnitsPerSecond,2);Iterations=$cpu.Iterations}
        MemoryVerification=[pscustomobject]@{RequestedMB=$memory.RequestedMB;AllocatedMB=$memory.AllocatedMB;VerifiedMB=[math]::Round([double]$memory.BytesVerified/1MB,0);Errors=$memory.Errors;Seconds=[math]::Round($memory.Seconds,1);Passes=$memory.Passes;TargetSystemUsagePercent=$memoryTarget.TargetPercent}
        DiskStress=[pscustomobject]@{Enabled=[bool]$cfg.DiskEnabled;Status=$diskStatus;ProcessExitCode=$diskExit;ReadMBps=$(if($diskMetrics){$diskMetrics.ReadMBps}else{$null});ReadIOPS=$(if($diskMetrics){$diskMetrics.ReadIOPS}else{$null});AverageReadLatencyMs=$(if($diskMetrics){$diskMetrics.AverageReadLatencyMs}else{$null});BlockSizeKB=[int]$cfg.DiskBlockSizeKB;QueueDepth=[int]$cfg.DiskQueueDepth;Threads=[int]$cfg.DiskThreads;WritePercent=0;Error=$diskParseError;XmlPath=$diskOut;StdErrPath=$diskErr}
        GraphicsStress=[pscustomobject]@{Enabled=[bool]$cfg.GraphicsEnabled;Required=$requiredGraphics;Status=$gpuStatus;ProcessExitCode=$gpuExit;Engine='WinSAT DWM composition workload';Error=$gpuError;OutputPath=$gpuOut;StdErrPath=$gpuErr}
        Utilization=$utilization;Sensors=$sensorSummary;LoadSamples=@($loadSamples)
    }
    Write-SitecStepResult -RunPath $RunPath -Step '40-full-system-burnin' -Value $result | Out-Null
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'BurnIn' -Step 'FullSystem' -Status $result.Status -Level $(if($result.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("Burn-in finished in {0}s. CPU avg/peak {1}/{2}%, RAM peak {3}%, Disk {4}, GPU {5}." -f $result.ActualSeconds,$utilization.CPU.Average,$utilization.CPU.Peak,$utilization.Memory.Peak,$diskStatus,$gpuStatus) -Data $utilization
    $result
}
