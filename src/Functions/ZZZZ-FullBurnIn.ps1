# Concurrent production burn-in engine.
# Loaded after the legacy benchmark/compatibility layers so the public
# benchmark and validation entry points below become the production defaults.

$script:SitecEvidenceHashCore = ${function:Write-SitecEvidenceHashes}

function Initialize-SitecBurnInType {
    if ('SitecQcBurnInV2' -as [type]) { return }

    $code=@'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

public class SitecCpuBurnResult {
    public double WorkUnitsPerSecond { get; set; }
    public long Iterations { get; set; }
    public int Threads { get; set; }
    public int DutyPercent { get; set; }
    public double Seconds { get; set; }
}

public class SitecMemoryBurnResult {
    public long BytesVerified { get; set; }
    public long Errors { get; set; }
    public double Seconds { get; set; }
    public int RequestedMB { get; set; }
    public int AllocatedMB { get; set; }
    public int Passes { get; set; }
}

public static class SitecQcBurnInV2 {
    public static Task<SitecCpuBurnResult> CpuAsync(int seconds, int threads, int dutyPercent) {
        return Task.Factory.StartNew(() => {
            if (seconds < 1) seconds = 1;
            if (threads < 1) threads = Environment.ProcessorCount;
            if (dutyPercent < 10) dutyPercent = 10;
            if (dutyPercent > 100) dutyPercent = 100;

            var global = Stopwatch.StartNew();
            long[] counts = new long[threads];
            Thread[] workers = new Thread[threads];

            for (int t = 0; t < threads; t++) {
                int slot = t;
                workers[t] = new Thread(() => {
                    byte[] buffer = new byte[256 * 1024];
                    for (int i = 0; i < buffer.Length; i += 4096)
                        buffer[i] = (byte)((i + slot * 17) & 0xFF);

                    ulong x = 0x9E3779B97F4A7C15UL ^ (ulong)(slot + 1);
                    double f = 1.000001 + (slot * 0.000001);
                    using (var sha = SHA256.Create()) {
                        while (global.Elapsed.TotalSeconds < seconds) {
                            var cycle = Stopwatch.StartNew();
                            while (cycle.ElapsedMilliseconds < dutyPercent && global.Elapsed.TotalSeconds < seconds) {
                                for (int j = 0; j < 2048; j++) {
                                    x ^= x << 13;
                                    x ^= x >> 7;
                                    x ^= x << 17;
                                    f = Math.Sqrt(Math.Abs((f * 1.0000001192092896) + ((x & 0xFFFF) * 0.0000001)));
                                    f = (f * 1.0000001) + 0.0000003;
                                    if (f > 1000.0 || Double.IsNaN(f) || Double.IsInfinity(f)) f = 1.000001;
                                }
                                buffer[(counts[slot] * 4096) % buffer.Length] ^= (byte)x;
                                sha.ComputeHash(buffer);
                                counts[slot]++;
                            }
                            int sleep = 100 - dutyPercent;
                            if (sleep > 0 && global.Elapsed.TotalSeconds < seconds)
                                Thread.Sleep(sleep);
                        }
                    }
                });
                workers[t].IsBackground = true;
                workers[t].Priority = ThreadPriority.Normal;
                workers[t].Start();
            }

            for (int i = 0; i < workers.Length; i++) workers[i].Join();
            global.Stop();
            long total = 0;
            for (int i = 0; i < counts.Length; i++) total += counts[i];

            return new SitecCpuBurnResult {
                WorkUnitsPerSecond = total / Math.Max(global.Elapsed.TotalSeconds, 0.001),
                Iterations = total,
                Threads = threads,
                DutyPercent = dutyPercent,
                Seconds = global.Elapsed.TotalSeconds
            };
        }, TaskCreationOptions.LongRunning);
    }

    public static Task<SitecMemoryBurnResult> MemoryAsync(int seconds, int targetMB, int workers) {
        return Task.Factory.StartNew(() => {
            if (seconds < 1) seconds = 1;
            if (targetMB < 128) targetMB = 128;
            if (workers < 1) workers = 1;
            if (workers > 8) workers = 8;

            const int chunkMB = 32;
            var chunks = new List<ulong[]>();
            int remaining = targetMB;
            int allocatedMB = 0;
            while (remaining > 0) {
                int mb = Math.Min(chunkMB, remaining);
                try {
                    chunks.Add(new ulong[(mb * 1024 * 1024) / 8]);
                    allocatedMB += mb;
                    remaining -= mb;
                }
                catch (OutOfMemoryException) {
                    break;
                }
            }

            if (allocatedMB < 128)
                throw new OutOfMemoryException("Unable to reserve enough physical memory for the burn-in workload.");

            var sw = Stopwatch.StartNew();
            long errors = 0;
            long verified = 0;
            int passes = 0;
            ulong[] patterns = new ulong[] {
                0xAAAAAAAAAAAAAAAAUL,
                0x5555555555555555UL,
                0x0000000000000000UL,
                0xFFFFFFFFFFFFFFFFUL
            };

            while (sw.Elapsed.TotalSeconds < seconds) {
                ulong basePattern = patterns[passes % patterns.Length] ^ ((ulong)passes * 0x9E3779B97F4A7C15UL);
                var options = new ParallelOptions { MaxDegreeOfParallelism = workers };
                Parallel.For(0, chunks.Count, options, index => {
                    ulong[] data = chunks[index];
                    ulong pattern = basePattern ^ ((ulong)(index + 1) * 0xD6E8FEB86659FD93UL);
                    long localErrors = 0;

                    for (long i = 0; i < data.LongLength; i++)
                        data[i] = pattern ^ ((ulong)i * 0xA24BAED4963EE407UL);

                    Thread.MemoryBarrier();

                    for (long i = 0; i < data.LongLength; i++) {
                        ulong expected = pattern ^ ((ulong)i * 0xA24BAED4963EE407UL);
                        if (data[i] != expected) localErrors++;
                    }

                    if (localErrors != 0) Interlocked.Add(ref errors, localErrors);
                    Interlocked.Add(ref verified, data.LongLength * 8L);
                });
                passes++;
            }

            sw.Stop();
            GC.KeepAlive(chunks);
            return new SitecMemoryBurnResult {
                BytesVerified = verified,
                Errors = errors,
                Seconds = sw.Elapsed.TotalSeconds,
                RequestedMB = targetMB,
                AllocatedMB = allocatedMB,
                Passes = passes
            };
        }, TaskCreationOptions.LongRunning);
    }
}
'@

    Add-Type -TypeDefinition $code -Language CSharp
}

function Get-SitecBurnInMemoryTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalMB=[math]::Floor([double]$os.TotalVisibleMemorySize/1024)
    $freeMB=[math]::Floor([double]$os.FreePhysicalMemory/1024)
    $usedMB=[math]::Max(0,$totalMB-$freeMB)

    $cfg=$Context.Settings.BurnIn
    $targetPercent=[double]$cfg.MemoryTargetPercent
    $reserveMB=[int]$cfg.MemoryReserveMB
    $minMB=[int]$cfg.MemoryMinimumMB
    $maxMB=[int]$cfg.MemoryMaximumMB

    $desiredUsedMB=[math]::Floor($totalMB*($targetPercent/100.0))
    $needMB=[math]::Floor($desiredUsedMB-$usedMB)
    $safeFreeMB=[math]::Max(128,$freeMB-$reserveMB)
    $targetMB=[int][math]::Min($needMB,$safeFreeMB)
    $targetMB=[int][math]::Min($targetMB,$maxMB)
    if ($targetMB -lt $minMB) { $targetMB=[int][math]::Min($minMB,$safeFreeMB) }
    if ($targetMB -lt 128) { $targetMB=128 }

    [pscustomobject]@{
        TotalMB=[int]$totalMB
        FreeBeforeMB=[int]$freeMB
        UsedBeforeMB=[int]$usedMB
        TargetPercent=$targetPercent
        AllocationTargetMB=$targetMB
        ReserveMB=$reserveMB
    }
}

function Get-SitecLoadSnapshot {
    [CmdletBinding()]
    param()

    $cpu=$null;$mem=$null;$disk=$null;$gpu=$null
    try {
        $p=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $p.PercentProcessorTime) { $cpu=[double]$p.PercentProcessorTime }
    } catch {}

    try {
        $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total=[double]$os.TotalVisibleMemorySize
        $free=[double]$os.FreePhysicalMemory
        if ($total -gt 0) { $mem=[math]::Round((($total-$free)/$total)*100,2) }
    } catch {}

    try {
        $d=Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $d.PercentDiskTime) { $disk=[math]::Min(100,[double]$d.PercentDiskTime) }
    } catch {}

    try {
        $engines=@(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $null -ne $_.UtilizationPercentage })
        if ($engines.Count -gt 0) {
            $m=$engines | Measure-Object -Property UtilizationPercentage -Maximum
            if ($null -ne $m.Maximum) { $gpu=[math]::Min(100,[double]$m.Maximum) }
        }
    } catch {
        try {
            $c=Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
            $m=$c.CounterSamples | Measure-Object -Property CookedValue -Maximum
            if ($null -ne $m.Maximum) { $gpu=[math]::Min(100,[double]$m.Maximum) }
        } catch {}
    }

    [pscustomobject]@{
        Time=(Get-Date).ToString('o')
        CpuPercent=$cpu
        MemoryUsedPercent=$mem
        DiskActivePercent=$disk
        GpuEnginePercent=$gpu
    }
}

function Get-SitecLoadSummary {
    param([AllowNull()][AllowEmptyCollection()]$Samples)
    $rows=@($Samples | Where-Object { $null -ne $_ })

    function MeasureField([string]$Name) {
        $values=@($rows | ForEach-Object { $_.$Name } | Where-Object { $null -ne $_ })
        if ($values.Count -eq 0) { return [pscustomobject]@{Average=$null;Peak=$null;Samples=0} }
        $m=$values | Measure-Object -Average -Maximum
        [pscustomobject]@{Average=[math]::Round([double]$m.Average,1);Peak=[math]::Round([double]$m.Maximum,1);Samples=$values.Count}
    }

    [pscustomobject]@{
        SampleCount=$rows.Count
        CPU=MeasureField 'CpuPercent'
        Memory=MeasureField 'MemoryUsedPercent'
        Disk=MeasureField 'DiskActivePercent'
        GPU=MeasureField 'GpuEnginePercent'
    }
}

function Start-SitecBurnInProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath
    )

    Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath
}

function Set-SitecBurnInUiProgress {
    param([Parameter(Mandatory)][string]$RunPath,[int]$Percent,[string]$Message)
    $statusPath=Join-Path $RunPath 'status.json'
    if (-not (Test-Path -LiteralPath $statusPath)) { return }
    try {
        $status=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.Stage='Full System Burn-In'
        $status.Percent=[math]::Max(1,[math]::Min(99,$Percent))
        $status.Message=$Message
        $status.UpdatedAt=(Get-Date).ToString('o')
        $tmp=$statusPath+'.burnin.tmp'
        $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $statusPath -Force
    } catch {}
}

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

    $diskProcess=$null;$gpuProcess=$null;$diskStatus='SKIPPED';$gpuStatus='SKIPPED'
    $diskMetrics=$null
    $diskTarget=$null

    if ([bool]$cfg.DiskEnabled) {
        $diskExe=Join-Path $Context.ProjectRoot ([string]$Context.Settings.DiskSpd.ExeRelativePath)
        if (Test-Path -LiteralPath $diskExe) {
            $drive=[string]$Context.Settings.DiskSpd.TargetDrive
            if ([string]::IsNullOrWhiteSpace($drive)) { $drive='C:' }
            $testDir=Join-Path ($drive+'\') 'SitecQC-Temp'
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $diskTarget=Join-Path $testDir 'diskspd-burnin.dat'
            $size=[int]$cfg.DiskTargetSizeMB
            $block=[int]$cfg.DiskBlockSizeKB
            $queue=[int]$cfg.DiskQueueDepth
            $threads=[int]$cfg.DiskThreads
            $diskOut=Join-Path $benchDir 'disk-burnin.xml'
            $diskErr=Join-Path $benchDir 'disk-burnin.err.txt'
            # Read-only, no software cache: sustained NVMe/controller/PCIe load without adding avoidable NAND wear.
            $args="-c${size}M -b${block}K -r -o$queue -t$threads -W5 -d$duration -C1 -Sh -L -w0 -Rxml `"$diskTarget`""
            $diskProcess=Start-SitecBurnInProcess -FilePath $diskExe -Arguments $args -StdOutPath $diskOut -StdErrPath $diskErr
            $diskStatus='RUNNING'
        } else {
            $diskStatus='DEPENDENCY_MISSING'
        }
    }

    if ([bool]$cfg.GraphicsEnabled -and (Get-Command winsat.exe -ErrorAction SilentlyContinue)) {
        $gpuOut=Join-Path $benchDir 'graphics-burnin.out.txt'
        $gpuErr=Join-Path $benchDir 'graphics-burnin.err.txt'
        $normal=[int]$cfg.GraphicsNormalWindows
        $glass=[int]$cfg.GraphicsGlassWindows
        # DWM composition is used because WinSAT's old D3D assessment no longer produces real-time
        # 3D scores on modern Windows. This still exercises the active graphics adapter and shared memory path.
        $gpuArgs="dwm -normalw $normal -glassw $glass -time $duration -width 1920 -height 1080 -winwidth 1920 -winheight 1080 -nodisp -nolock -v"
        try {
            $gpuProcess=Start-SitecBurnInProcess -FilePath 'winsat.exe' -Arguments $gpuArgs -StdOutPath $gpuOut -StdErrPath $gpuErr
            $gpuStatus='RUNNING'
        } catch {
            $gpuStatus='FAIL'
        }
    } elseif ([bool]$cfg.GraphicsEnabled) {
        $gpuStatus='UNAVAILABLE'
    }

    $started=Get-Date
    $cpuTask=[SitecQcBurnInV2]::CpuAsync($duration,[Environment]::ProcessorCount,$cpuDuty)
    $memoryTask=[SitecQcBurnInV2]::MemoryAsync($duration,[int]$memoryTarget.AllocationTargetMB,$memoryWorkers)

    $loadSamples=@()
    $sensorSnapshots=@()
    $hardDeadline=$started.AddSeconds($duration+45)

    while ($true) {
        $cpuDone=$cpuTask.IsCompleted
        $memDone=$memoryTask.IsCompleted
        $diskDone=($null -eq $diskProcess -or $diskProcess.HasExited)
        $gpuDone=($null -eq $gpuProcess -or $gpuProcess.HasExited)
        if ($cpuDone -and $memDone -and $diskDone -and $gpuDone) { break }
        if ((Get-Date) -gt $hardDeadline) { break }

        $loadSamples += Get-SitecLoadSnapshot
        $sensors=@(Get-SitecSensorSnapshot -Context $Context)
        if ($sensors.Count -gt 0) { $sensorSnapshots += $sensors }

        $elapsed=[math]::Min($duration,[math]::Max(0,((Get-Date)-$started).TotalSeconds))
        $ratio=$elapsed/[double]$duration
        $uiPercent=40+[int][math]::Floor($ratio*40)
        $last=$loadSamples[-1]
        $loadText=@()
        if ($null -ne $last.CpuPercent) { $loadText += ('CPU {0:N0}%' -f $last.CpuPercent) }
        if ($null -ne $last.MemoryUsedPercent) { $loadText += ('RAM {0:N0}%' -f $last.MemoryUsedPercent) }
        if ($null -ne $last.DiskActivePercent) { $loadText += ('Disk {0:N0}%' -f $last.DiskActivePercent) }
        if ($null -ne $last.GpuEnginePercent) { $loadText += ('GPU {0:N0}%' -f $last.GpuEnginePercent) }
        Set-SitecBurnInUiProgress -RunPath $RunPath -Percent $uiPercent -Message ("Concurrent burn-in {0:N0}/{1}s | {2}" -f $elapsed,$duration,($loadText -join ' | '))
        Start-Sleep -Seconds $sampleSeconds
    }

    if (-not $cpuTask.IsCompleted -or -not $memoryTask.IsCompleted) {
        throw 'CPU/RAM burn-in exceeded the allowed completion window.'
    }
    $cpu=$cpuTask.GetAwaiter().GetResult()
    $memory=$memoryTask.GetAwaiter().GetResult()

    if ($null -ne $diskProcess) {
        if (-not $diskProcess.HasExited) { try { $diskProcess.Kill() } catch {} }
        if ($diskProcess.HasExited -and $diskProcess.ExitCode -eq 0) {
            try {
                $diskMetrics=Get-SitecDiskSpdMetrics -XmlPath (Join-Path $benchDir 'disk-burnin.xml')
                $diskStatus='PASS'
            } catch {
                $diskStatus='FAIL'
            }
        } else { $diskStatus='FAIL' }
    }

    if ($null -ne $gpuProcess) {
        if (-not $gpuProcess.HasExited) { try { $gpuProcess.Kill() } catch {} }
        if ($gpuProcess.HasExited -and $gpuProcess.ExitCode -eq 0) { $gpuStatus='PASS' } else { $gpuStatus='FAIL' }
    }

    if ($diskTarget) {
        Remove-Item -LiteralPath $diskTarget -Force -ErrorAction SilentlyContinue
        $parent=Split-Path -Parent $diskTarget
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }

    $tailSensors=@(Get-SitecSensorSnapshot -Context $Context)
    if ($tailSensors.Count -gt 0) { $sensorSnapshots += $tailSensors }
    $sensorSummary=@(Get-SitecSensorSummary -Snapshots $sensorSnapshots)
    $utilization=Get-SitecLoadSummary -Samples $loadSamples
    $finished=Get-Date

    $requiredDisk=[bool]$cfg.DiskEnabled
    $requiredGraphics=[bool]$cfg.GraphicsRequired
    $pass=($memory.Errors -eq 0)
    if ($requiredDisk -and $diskStatus -ne 'PASS') { $pass=$false }
    if ($requiredGraphics -and $gpuStatus -ne 'PASS') { $pass=$false }

    [pscustomobject]@{
        Status=if($pass){'PASS'}else{'FAIL'}
        Required=$true
        StartedAt=$started.ToString('o')
        FinishedAt=$finished.ToString('o')
        DurationSeconds=$duration
        ActualSeconds=[math]::Round(($finished-$started).TotalSeconds,1)
        CpuStress=[pscustomobject]@{
            Seconds=[math]::Round($cpu.Seconds,1)
            Threads=$cpu.Threads
            DutyPercent=$cpu.DutyPercent
            HashWorkMBps=[math]::Round($cpu.WorkUnitsPerSecond,2)
            WorkUnitsPerSecond=[math]::Round($cpu.WorkUnitsPerSecond,2)
            Iterations=$cpu.Iterations
        }
        MemoryVerification=[pscustomobject]@{
            RequestedMB=$memory.RequestedMB
            AllocatedMB=$memory.AllocatedMB
            VerifiedMB=[math]::Round([double]$memory.BytesVerified/1MB,0)
            Errors=$memory.Errors
            Seconds=[math]::Round($memory.Seconds,1)
            Passes=$memory.Passes
            TargetSystemUsagePercent=$memoryTarget.TargetPercent
        }
        DiskStress=[pscustomobject]@{
            Enabled=[bool]$cfg.DiskEnabled
            Status=$diskStatus
            ReadMBps=$(if($diskMetrics){$diskMetrics.ReadMBps}else{$null})
            ReadIOPS=$(if($diskMetrics){$diskMetrics.ReadIOPS}else{$null})
            AverageReadLatencyMs=$(if($diskMetrics){$diskMetrics.AverageReadLatencyMs}else{$null})
            BlockSizeKB=[int]$cfg.DiskBlockSizeKB
            QueueDepth=[int]$cfg.DiskQueueDepth
            Threads=[int]$cfg.DiskThreads
            WritePercent=0
        }
        GraphicsStress=[pscustomobject]@{
            Enabled=[bool]$cfg.GraphicsEnabled
            Required=$requiredGraphics
            Status=$gpuStatus
            Engine='WinSAT DWM composition workload'
        }
        Utilization=$utilization
        Sensors=$sensorSummary
        LoadSamples=@($loadSamples)
    }
}

function Invoke-SitecBenchmarkSuite {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)

    $started=Get-Date
    Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 30 -Message 'Performance qualification: CPU and memory metrics'
    try {
        $winsat=Invoke-SitecWinSat -Context $Context -RunPath $RunPath
    } catch {
        $winsat=[pscustomobject]@{Available=$true;Status='FAIL';CpuCompressionMBps=$null;MemoryMBps=$null;Error=$_.Exception.Message}
    }

    Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 35 -Message 'Performance qualification: Samsung NVMe throughput and IOPS'
    try {
        $disk=Invoke-SitecDiskSpd -Context $Context -RunPath $RunPath
    } catch {
        $disk=[pscustomobject]@{Available=$true;Required=[bool]$Context.Settings.DiskSpd.Enabled;Status='FAIL';SequentialReadMBps=$null;SequentialWriteMBps=$null;RandomReadIOPS=$null;Error=$_.Exception.Message}
    }

    Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 40 -Message 'Starting concurrent CPU + RAM + NVMe + graphics burn-in'
    try {
        $burn=Invoke-SitecFullSystemBurnIn -Context $Context -RunPath $RunPath
    } catch {
        $burn=[pscustomobject]@{
            Status='FAIL';Required=$true;Error=$_.Exception.Message;DurationSeconds=0;ActualSeconds=0;
            CpuStress=[pscustomobject]@{Seconds=0;Threads=0;DutyPercent=0;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0};
            MemoryVerification=[pscustomobject]@{RequestedMB=0;AllocatedMB=0;VerifiedMB=0;Errors=[long]::MaxValue;Seconds=0;Passes=0};
            DiskStress=[pscustomobject]@{Enabled=$true;Status='FAIL';ReadMBps=$null;ReadIOPS=$null;AverageReadLatencyMs=$null};
            GraphicsStress=[pscustomobject]@{Enabled=$true;Required=$false;Status='FAIL';Engine='WinSAT DWM composition workload'};
            Utilization=(Get-SitecLoadSummary @());Sensors=@();LoadSamples=@()
        }
    }

    $whea=Get-SitecWheaEvents -Since $started
    [pscustomobject]@{
        StartedAt=$started.ToString('o')
        FinishedAt=(Get-Date).ToString('o')
        WinSAT=$winsat
        DiskSpd=$disk
        BurnIn=$burn
        Stress=$burn
        WHEA=[pscustomobject]@{Count=@($whea).Count;Events=@($whea)}
    }
}

function Test-SitecBenchmarkResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Benchmark,[Parameter(Mandatory)]$Profile)

    $t=$Profile.Thresholds
    $checks=@()
    $burn=$null
    if ($Benchmark.PSObject.Properties['BurnIn']) { $burn=$Benchmark.BurnIn }
    elseif ($Benchmark.PSObject.Properties['Stress']) { $burn=$Benchmark.Stress }

    if ($burn) {
        $checks += New-SitecCheck 'Full-system burn-in' 'PASS' ([string]$burn.Status) ([string]$burn.Status -eq 'PASS')
        $checks += New-SitecCheck 'Memory verification errors' ("<= $($t.MaximumMemoryVerificationErrors)") ([string]$burn.MemoryVerification.Errors) ([long]$burn.MemoryVerification.Errors -le [long]$t.MaximumMemoryVerificationErrors)

        if ($burn.PSObject.Properties['DiskStress'] -and $burn.DiskStress.Enabled) {
            $checks += New-SitecCheck 'Burn-in NVMe workload' 'PASS' ([string]$burn.DiskStress.Status) ([string]$burn.DiskStress.Status -eq 'PASS')
            if ($null -ne $burn.DiskStress.ReadMBps -and $t.PSObject.Properties['MinimumBurnInDiskReadMBps']) {
                $checks += New-SitecCheck 'Burn-in NVMe throughput' (">= $($t.MinimumBurnInDiskReadMBps) MB/s") ("$($burn.DiskStress.ReadMBps) MB/s") ([double]$burn.DiskStress.ReadMBps -ge [double]$t.MinimumBurnInDiskReadMBps)
            }
        }

        if ($burn.PSObject.Properties['GraphicsStress'] -and $burn.GraphicsStress.Enabled) {
            $severity=if($burn.GraphicsStress.Required){'Error'}else{'Warning'}
            $checks += New-SitecCheck 'Graphics burn-in workload' 'PASS' ([string]$burn.GraphicsStress.Status) ([string]$burn.GraphicsStress.Status -eq 'PASS') $severity
        }

        if ($burn.PSObject.Properties['Utilization']) {
            if ($null -ne $burn.Utilization.CPU.Average -and $t.PSObject.Properties['MinimumBurnInCpuAveragePercent']) {
                $checks += New-SitecCheck 'CPU average load during burn-in' (">= $($t.MinimumBurnInCpuAveragePercent)%") ("$($burn.Utilization.CPU.Average)%") ([double]$burn.Utilization.CPU.Average -ge [double]$t.MinimumBurnInCpuAveragePercent)
            }
            if ($null -ne $burn.Utilization.Memory.Peak -and $t.PSObject.Properties['MinimumBurnInMemoryPeakPercent']) {
                $checks += New-SitecCheck 'Peak RAM use during burn-in' (">= $($t.MinimumBurnInMemoryPeakPercent)%") ("$($burn.Utilization.Memory.Peak)%") ([double]$burn.Utilization.Memory.Peak -ge [double]$t.MinimumBurnInMemoryPeakPercent)
            }
            if ($null -ne $burn.Utilization.GPU.Peak -and $t.PSObject.Properties['MinimumBurnInGpuPeakPercent']) {
                $checks += New-SitecCheck 'GPU peak load during burn-in' (">= $($t.MinimumBurnInGpuPeakPercent)%") ("$($burn.Utilization.GPU.Peak)%") ([double]$burn.Utilization.GPU.Peak -ge [double]$t.MinimumBurnInGpuPeakPercent) 'Warning'
            }
        }
    }

    $checks += New-SitecCheck 'WHEA hardware errors' ("<= $($t.MaximumWheaEvents)") ([string]$Benchmark.WHEA.Count) ([int]$Benchmark.WHEA.Count -le [int]$t.MaximumWheaEvents)

    if ($Benchmark.WinSAT.Available) {
        $checks += New-SitecCheck 'WinSAT execution' 'PASS' ([string]$Benchmark.WinSAT.Status) ([string]$Benchmark.WinSAT.Status -eq 'PASS')
        if ($null -ne $Benchmark.WinSAT.CpuCompressionMBps) {
            $checks += New-SitecCheck 'CPU compression' (">= $($t.MinimumWinSatCpuCompressionMBps) MB/s") ("$($Benchmark.WinSAT.CpuCompressionMBps) MB/s") ([double]$Benchmark.WinSAT.CpuCompressionMBps -ge [double]$t.MinimumWinSatCpuCompressionMBps) 'Warning'
        }
        if ($null -ne $Benchmark.WinSAT.MemoryMBps) {
            $checks += New-SitecCheck 'Memory bandwidth' (">= $($t.MinimumWinSatMemoryMBps) MB/s") ("$($Benchmark.WinSAT.MemoryMBps) MB/s") ([double]$Benchmark.WinSAT.MemoryMBps -ge [double]$t.MinimumWinSatMemoryMBps) 'Warning'
        }
    } else {
        $checks += New-SitecCheck 'WinSAT availability' 'Available' 'Unavailable' $false 'Warning'
    }

    if ($Benchmark.DiskSpd.Available) {
        $checks += New-SitecCheck 'DiskSpd execution' 'PASS' ([string]$Benchmark.DiskSpd.Status) ([string]$Benchmark.DiskSpd.Status -eq 'PASS')
        if ($null -ne $Benchmark.DiskSpd.SequentialReadMBps) {
            $checks += New-SitecCheck 'SSD sequential read' (">= $($t.MinimumDiskSpdSeqReadMBps) MB/s") ("$($Benchmark.DiskSpd.SequentialReadMBps) MB/s") ([double]$Benchmark.DiskSpd.SequentialReadMBps -ge [double]$t.MinimumDiskSpdSeqReadMBps)
        }
        if ($null -ne $Benchmark.DiskSpd.SequentialWriteMBps) {
            $checks += New-SitecCheck 'SSD sequential write' (">= $($t.MinimumDiskSpdSeqWriteMBps) MB/s") ("$($Benchmark.DiskSpd.SequentialWriteMBps) MB/s") ([double]$Benchmark.DiskSpd.SequentialWriteMBps -ge [double]$t.MinimumDiskSpdSeqWriteMBps)
        }
        if ($null -ne $Benchmark.DiskSpd.RandomReadIOPS) {
            $checks += New-SitecCheck 'SSD 4K random read' (">= $($t.MinimumDiskSpdRandomReadIOPS) IOPS") ("$($Benchmark.DiskSpd.RandomReadIOPS) IOPS") ([double]$Benchmark.DiskSpd.RandomReadIOPS -ge [double]$t.MinimumDiskSpdRandomReadIOPS)
        }
    } else {
        $severity=if($Benchmark.DiskSpd.PSObject.Properties['Required'] -and $Benchmark.DiskSpd.Required){'Error'}else{'Warning'}
        $checks += New-SitecCheck 'DiskSpd availability' 'Installed' ([string]$Benchmark.DiskSpd.Status) $false $severity
    }

    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{Status=if($failed.Count -eq 0){'PASS'}else{'FAIL'};Checks=@($checks)}
}

function Add-SitecBurnInSummaryToCertificate {
    param([Parameter(Mandatory)][string]$RunPath)

    $manifestPath=Join-Path $RunPath 'hardware-qc-manifest.json'
    $htmlPath=Join-Path $RunPath 'QC-Certificate.html'
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $htmlPath)) { return $false }

    try {
        $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $m.Benchmark -or -not $m.Benchmark.PSObject.Properties['BurnIn']) { return $false }
        $b=$m.Benchmark.BurnIn
        if (-not $b -or [string]$b.Status -eq 'SKIPPED') { return $false }

        $rows=@()
        $rows += '<tr><th>Mode</th><td>Concurrent CPU + RAM + NVMe + Graphics</td><th>Status</th><td><b>'+ (ConvertTo-SitecHtml $b.Status) +'</b></td></tr>'
        $rows += '<tr><th>Duration</th><td>'+ (ConvertTo-SitecHtml ("$($b.ActualSeconds) s")) +'</td><th>CPU duty / threads</th><td>'+ (ConvertTo-SitecHtml ("$($b.CpuStress.DutyPercent)% / $($b.CpuStress.Threads)")) +'</td></tr>'
        $rows += '<tr><th>RAM allocated</th><td>'+ (ConvertTo-SitecHtml ("$($b.MemoryVerification.AllocatedMB) MB")) +'</td><th>RAM verified / errors</th><td>'+ (ConvertTo-SitecHtml ("$($b.MemoryVerification.VerifiedMB) MB / $($b.MemoryVerification.Errors)")) +'</td></tr>'
        if ($b.DiskStress -and $null -ne $b.DiskStress.ReadMBps) {
            $rows += '<tr><th>NVMe sustained read</th><td>'+ (ConvertTo-SitecHtml ("$($b.DiskStress.ReadMBps) MB/s")) +'</td><th>Graphics workload</th><td>'+ (ConvertTo-SitecHtml $b.GraphicsStress.Status) +'</td></tr>'
        }
        if ($b.Utilization) {
            $cpu="Avg $($b.Utilization.CPU.Average)% / Peak $($b.Utilization.CPU.Peak)%"
            $ram="Avg $($b.Utilization.Memory.Average)% / Peak $($b.Utilization.Memory.Peak)%"
            $disk="Avg $($b.Utilization.Disk.Average)% / Peak $($b.Utilization.Disk.Peak)%"
            $gpu="Avg $($b.Utilization.GPU.Average)% / Peak $($b.Utilization.GPU.Peak)%"
            $rows += '<tr><th>CPU utilization</th><td>'+ (ConvertTo-SitecHtml $cpu) +'</td><th>RAM utilization</th><td>'+ (ConvertTo-SitecHtml $ram) +'</td></tr>'
            $rows += '<tr><th>Disk utilization</th><td>'+ (ConvertTo-SitecHtml $disk) +'</td><th>GPU utilization</th><td>'+ (ConvertTo-SitecHtml $gpu) +'</td></tr>'
        }

        $section='<section><h2>Full System Burn-In</h2><table><tbody>'+($rows -join '')+'</tbody></table></section>'
        $html=Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
        if ($html -match '<h2>Full System Burn-In</h2>') { return $false }
        $html=$html.Replace('<div class="footer">',$section+'<div class="footer">')
        Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Write-SitecEvidenceHashes {
    param([Parameter(Mandatory)][string]$RunPath)

    $changed=Add-SitecBurnInSummaryToCertificate -RunPath $RunPath
    $result=& $script:SitecEvidenceHashCore -RunPath $RunPath

    # The core helper only regenerates PDF when it injects the identity hash.
    # If the burn-in section was the only HTML change, ensure PDF follows it too.
    if ($changed) {
        $htmlPath=Join-Path $RunPath 'QC-Certificate.html'
        $pdfPath=Join-Path $RunPath 'QC-Certificate.pdf'
        if (Test-Path -LiteralPath $pdfPath) {
            Remove-Item -LiteralPath $pdfPath -Force -ErrorAction SilentlyContinue
            try { [void](Convert-SitecHtmlToPdf -HtmlPath $htmlPath -PdfPath $pdfPath) } catch {}
        }
    }
    $result
}
