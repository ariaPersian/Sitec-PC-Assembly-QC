function Invoke-SitecProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [int]$TimeoutSeconds = 300
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch {}
        throw "Process timed out: $FilePath $Arguments"
    }
    $stdout = $out.Result
    $stderr = $err.Result
    Set-Content -LiteralPath $StdOutPath -Value $stdout -Encoding UTF8
    Set-Content -LiteralPath $StdErrPath -Value $stderr -Encoding UTF8
    [pscustomobject]@{ ExitCode=$p.ExitCode; StdOut=$stdout; StdErr=$stderr }
}

function Get-SitecWheaEvents {
    param([Parameter(Mandatory)][datetime]$Since)
    try {
        @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$Since } -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    TimeCreated = $_.TimeCreated.ToString('o')
                    Id = $_.Id
                    Level = $_.LevelDisplayName
                    Message = $_.Message
                    RecordId = $_.RecordId
                }
            })
    } catch {
        @()
    }
}

function Initialize-SitecStressType {
    if ('SitecQcStress' -as [type]) { return }
    $code = @'
using System;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading.Tasks;

public class SitecCpuStressResult {
    public double MegabytesPerSecond { get; set; }
    public long Iterations { get; set; }
    public int Threads { get; set; }
}
public class SitecMemoryStressResult {
    public long BytesVerified { get; set; }
    public long Errors { get; set; }
    public double Seconds { get; set; }
}
public static class SitecQcStress {
    public static Task<SitecCpuStressResult> CpuAsync(int seconds, int threads) {
        return Task.Run(() => {
            if (threads < 1) threads = Environment.ProcessorCount;
            var sw = Stopwatch.StartNew();
            long[] counts = new long[threads];
            Task[] jobs = new Task[threads];
            for (int t = 0; t < threads; t++) {
                int slot = t;
                jobs[t] = Task.Run(() => {
                    byte[] buffer = new byte[1024 * 1024];
                    for (int i = 0; i < buffer.Length; i += 4096) buffer[i] = (byte)(i + slot);
                    using (var sha = SHA256.Create()) {
                        while (sw.Elapsed.TotalSeconds < seconds) {
                            sha.ComputeHash(buffer);
                            counts[slot]++;
                        }
                    }
                });
            }
            Task.WaitAll(jobs);
            sw.Stop();
            long total = 0;
            for (int i = 0; i < counts.Length; i++) total += counts[i];
            return new SitecCpuStressResult {
                Iterations = total,
                Threads = threads,
                MegabytesPerSecond = total / Math.Max(sw.Elapsed.TotalSeconds, 0.001)
            };
        });
    }

    public static SitecMemoryStressResult MemoryVerify(int totalMegabytes) {
        var sw = Stopwatch.StartNew();
        long errors = 0;
        long verified = 0;
        const int chunkMb = 128;
        int remaining = Math.Max(totalMegabytes, chunkMb);
        uint seed = 0x9E3779B9u;
        while (remaining > 0) {
            int mb = Math.Min(chunkMb, remaining);
            byte[] data = new byte[mb * 1024 * 1024];
            uint x = seed;
            for (int i = 0; i < data.Length; i += 4) {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5;
                data[i] = (byte)x;
                if (i + 1 < data.Length) data[i+1] = (byte)(x >> 8);
                if (i + 2 < data.Length) data[i+2] = (byte)(x >> 16);
                if (i + 3 < data.Length) data[i+3] = (byte)(x >> 24);
            }
            x = seed;
            for (int i = 0; i < data.Length; i += 4) {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5;
                if (data[i] != (byte)x) errors++;
                if (i + 1 < data.Length && data[i+1] != (byte)(x >> 8)) errors++;
                if (i + 2 < data.Length && data[i+2] != (byte)(x >> 16)) errors++;
                if (i + 3 < data.Length && data[i+3] != (byte)(x >> 24)) errors++;
            }
            verified += data.LongLength;
            remaining -= mb;
            seed += 0x1020304u;
        }
        sw.Stop();
        return new SitecMemoryStressResult { BytesVerified=verified, Errors=errors, Seconds=sw.Elapsed.TotalSeconds };
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp
}

function Get-SitecLibreHardwareMonitorDll {
    param([Parameter(Mandatory)]$Context)
    $rel = $Context.Settings.Sensors.LibreHardwareMonitorDllRelativePath
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }
    $candidate = Join-Path $Context.ProjectRoot $rel
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $found = Get-ChildItem -LiteralPath (Join-Path $Context.ProjectRoot 'tools\librehardwaremonitor') -Filter LibreHardwareMonitorLib.dll -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    $null
}

function Get-SitecSensorSnapshot {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Settings.Sensors.Enabled) { return @() }
    $dll = Get-SitecLibreHardwareMonitorDll -Context $Context
    if (-not $dll) { return @() }
    try {
        if (-not ('LibreHardwareMonitor.Hardware.Computer' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        $computer = New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled = $true
        $computer.IsGpuEnabled = $true
        $computer.IsMemoryEnabled = $true
        $computer.IsMotherboardEnabled = $true
        $computer.IsStorageEnabled = $true
        $computer.Open()
        $rows = New-Object System.Collections.Generic.List[object]
        $visit = {
            param($hw)
            $hw.Update()
            foreach ($s in $hw.Sensors) {
                if ($null -ne $s.Value) {
                    $rows.Add([pscustomobject]@{
                        Hardware = $hw.Name
                        HardwareType = [string]$hw.HardwareType
                        Sensor = $s.Name
                        SensorType = [string]$s.SensorType
                        Value = [double]$s.Value
                        Min = if ($null -ne $s.Min) { [double]$s.Min } else { $null }
                        Max = if ($null -ne $s.Max) { [double]$s.Max } else { $null }
                    })
                }
            }
            foreach ($sub in $hw.SubHardware) { & $visit $sub }
        }
        foreach ($hw in $computer.Hardware) { & $visit $hw }
        $computer.Close()
        @($rows)
    } catch {
        @()
    }
}

function Get-SitecSensorSummary {
    param([object[]]$Snapshots)
    if (-not $Snapshots -or $Snapshots.Count -eq 0) { return @() }
    $flat = @($Snapshots | ForEach-Object { $_ })
    @($flat | Group-Object Hardware,Sensor,SensorType | ForEach-Object {
        $vals = @($_.Group | Where-Object { $null -ne $_.Value } | Select-Object -ExpandProperty Value)
        if ($vals.Count -gt 0) {
            $f = $_.Group[0]
            [pscustomobject]@{
                Hardware=$f.Hardware
                Sensor=$f.Sensor
                SensorType=$f.SensorType
                Min=[math]::Round(($vals | Measure-Object -Minimum).Minimum,2)
                Max=[math]::Round(($vals | Measure-Object -Maximum).Maximum,2)
                Average=[math]::Round(($vals | Measure-Object -Average).Average,2)
            }
        }
    })
}

function Get-WinSatMetricFromXml {
    param([string]$Path,[string]$XPath)
    try {
        [xml]$x = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $node = $x.SelectSingleNode($XPath)
        if ($node -and $node.InnerText) { return [double]::Parse($node.InnerText,[Globalization.CultureInfo]::InvariantCulture) }
    } catch {}
    $null
}

function Invoke-SitecWinSat {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    if (-not $Context.Settings.WinSAT.Enabled -or -not (Get-Command winsat.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available=$false; Status='SKIPPED'; CpuCompressionMBps=$null; MemoryMBps=$null }
    }
    $benchDir = Join-Path $RunPath 'benchmark\winsat'
    New-Item -ItemType Directory -Path $benchDir -Force | Out-Null
    $cpuXml = Join-Path $benchDir 'cpu.xml'
    $memXml = Join-Path $benchDir 'memory.xml'
    $cpu = Invoke-SitecProcess -FilePath 'winsat.exe' -Arguments "cpu -compression -xml `"$cpuXml`"" -StdOutPath (Join-Path $benchDir 'cpu.out.txt') -StdErrPath (Join-Path $benchDir 'cpu.err.txt') -TimeoutSeconds 120
    $mem = Invoke-SitecProcess -FilePath 'winsat.exe' -Arguments "mem -mint 3 -maxt 8 -xml `"$memXml`"" -StdOutPath (Join-Path $benchDir 'memory.out.txt') -StdErrPath (Join-Path $benchDir 'memory.err.txt') -TimeoutSeconds 120
    $cpuMetric = Get-WinSatMetricFromXml -Path $cpuXml -XPath '//CPUMetrics/CompressionMetric'
    if ($null -eq $cpuMetric) { $cpuMetric = Get-WinSatMetricFromXml -Path $cpuXml -XPath '//CPUCompressionAssessment/Metric' }
    $memMetric = Get-WinSatMetricFromXml -Path $memXml -XPath '//MemoryMetrics/Bandwidth'
    if ($null -eq $memMetric) { $memMetric = Get-WinSatMetricFromXml -Path $memXml -XPath '//SystemMemoryBandwidth/Metric' }
    if ($null -eq $memMetric) {
        try {
            [xml]$mx = Get-Content -LiteralPath $memXml -Raw
            $n = $mx.SelectSingleNode('//*[contains(local-name(),"Bandwidth") and text()]')
            if ($n) { $memMetric = [double]::Parse($n.InnerText,[Globalization.CultureInfo]::InvariantCulture) }
        } catch {}
    }
    [pscustomobject]@{
        Available=$true
        Status=if ($cpu.ExitCode -eq 0 -and $mem.ExitCode -eq 0) {'PASS'} else {'FAIL'}
        CpuCompressionMBps=$cpuMetric
        MemoryMBps=$memMetric
        CpuExitCode=$cpu.ExitCode
        MemoryExitCode=$mem.ExitCode
    }
}

function Get-DiskSpdMetrics {
    param([Parameter(Mandatory)][string]$XmlPath)
    [xml]$x = Get-Content -LiteralPath $XmlPath -Raw
    $ts = [double]$x.Results.TimeSpan.TestTimeSeconds
    $targets = @($x.Results.TimeSpan.Thread.Target)
    $readCount = [double](($targets | Measure-Object -Property ReadCount -Sum).Sum)
    $writeCount = [double](($targets | Measure-Object -Property WriteCount -Sum).Sum)
    $readBytes = [double](($targets | Measure-Object -Property ReadBytes -Sum).Sum)
    $writeBytes = [double](($targets | Measure-Object -Property WriteBytes -Sum).Sum)
    [pscustomobject]@{
        TestTimeSeconds=$ts
        ReadIOPS=if ($ts -gt 0) {[math]::Round($readCount/$ts,2)} else {0}
        WriteIOPS=if ($ts -gt 0) {[math]::Round($writeCount/$ts,2)} else {0}
        ReadMBps=if ($ts -gt 0) {[math]::Round(($readBytes/$ts)/1MB,2)} else {0}
        WriteMBps=if ($ts -gt 0) {[math]::Round(($writeBytes/$ts)/1MB,2)} else {0}
        AverageReadLatencyMs=if ($x.Results.TimeSpan.Latency.AverageReadMilliseconds) {[double]$x.Results.TimeSpan.Latency.AverageReadMilliseconds} else {$null}
        AverageWriteLatencyMs=if ($x.Results.TimeSpan.Latency.AverageWriteMilliseconds) {[double]$x.Results.TimeSpan.Latency.AverageWriteMilliseconds} else {$null}
    }
}

function Invoke-SitecDiskSpd {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    if (-not $Context.Settings.DiskSpd.Enabled) { return [pscustomobject]@{ Available=$false; Required=$false; Status='SKIPPED' } }
    $exe = Join-Path $Context.ProjectRoot $Context.Settings.DiskSpd.ExeRelativePath
    if (-not (Test-Path -LiteralPath $exe)) { return [pscustomobject]@{ Available=$false; Required=$true; Status='DEPENDENCY_MISSING' } }

    $benchDir = Join-Path $RunPath 'benchmark\diskspd'
    New-Item -ItemType Directory -Path $benchDir -Force | Out-Null
    $drive = [string]$Context.Settings.DiskSpd.TargetDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive='C:' }
    $testDir = Join-Path ($drive + '\') 'SitecQC-Temp'
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    $target = Join-Path $testDir 'diskspd-qc.dat'
    $size = [int]$Context.Settings.DiskSpd.TargetSizeMB
    $seqSec = [int]$Context.Settings.DiskSpd.SequentialSeconds
    $rndSec = [int]$Context.Settings.DiskSpd.RandomSeconds

    $tests = @(
        @{Name='seq-read'; Args="-c${size}M -b1M -o8 -t1 -W2 -d$seqSec -C1 -Sh -L -Rxml `"$target`""},
        @{Name='seq-write'; Args="-c${size}M -b1M -o8 -t1 -W2 -d$seqSec -C1 -Sh -L -w100 -Rxml `"$target`""},
        @{Name='rnd-read'; Args="-c${size}M -b4K -r -o32 -t4 -W2 -d$rndSec -C1 -Sh -L -w0 -Rxml `"$target`""}
    )
    $results = @{}
    $ok = $true
    foreach ($t in $tests) {
        $out = Join-Path $benchDir ($t.Name + '.xml')
        $err = Join-Path $benchDir ($t.Name + '.err.txt')
        $r = Invoke-SitecProcess -FilePath $exe -Arguments $t.Args -StdOutPath $out -StdErrPath $err -TimeoutSeconds 180
        if ($r.ExitCode -ne 0) { $ok=$false; continue }
        try { $results[$t.Name] = Get-DiskSpdMetrics -XmlPath $out } catch { $ok=$false }
    }
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testDir -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Available=$true
        Required=$true
        Status=if ($ok) {'PASS'} else {'FAIL'}
        SequentialReadMBps=if ($results['seq-read']) {$results['seq-read'].ReadMBps} else {$null}
        SequentialWriteMBps=if ($results['seq-write']) {$results['seq-write'].WriteMBps} else {$null}
        RandomReadIOPS=if ($results['rnd-read']) {$results['rnd-read'].ReadIOPS} else {$null}
        RandomReadLatencyMs=if ($results['rnd-read']) {$results['rnd-read'].AverageReadLatencyMs} else {$null}
        Raw=$results
    }
}

function Invoke-SitecStress {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    Initialize-SitecStressType
    $cpuSeconds=[int]$Context.Settings.Stress.CpuSeconds
    $memMb=[int]$Context.Settings.Stress.MemoryTestMB
    $snapshots = New-Object System.Collections.Generic.List[object]
    $task = [SitecQcStress]::CpuAsync($cpuSeconds,[Environment]::ProcessorCount)
    while (-not $task.IsCompleted) {
        foreach ($s in @(Get-SitecSensorSnapshot -Context $Context)) { $snapshots.Add($s) }
        Start-Sleep -Seconds ([math]::Max([int]$Context.Settings.Sensors.SampleIntervalSeconds,1))
    }
    $cpu = $task.Result
    $memory = [SitecQcStress]::MemoryVerify($memMb)
    foreach ($s in @(Get-SitecSensorSnapshot -Context $Context)) { $snapshots.Add($s) }
    $summary = Get-SitecSensorSummary -Snapshots @($snapshots)
    [pscustomobject]@{
        Status=if ($memory.Errors -eq 0) {'PASS'} else {'FAIL'}
        CpuStress=[pscustomobject]@{
            Seconds=$cpuSeconds
            Threads=$cpu.Threads
            HashWorkMBps=[math]::Round($cpu.MegabytesPerSecond,2)
            Iterations=$cpu.Iterations
        }
        MemoryVerification=[pscustomobject]@{
            RequestedMB=$memMb
            VerifiedMB=[math]::Round([double]$memory.BytesVerified/1MB,0)
            Errors=$memory.Errors
            Seconds=[math]::Round($memory.Seconds,2)
        }
        Sensors=$summary
    }
}

function Invoke-SitecBenchmarkSuite {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    $started=Get-Date
    try {
        $winsat=Invoke-SitecWinSat -Context $Context -RunPath $RunPath
    } catch {
        $winsat=[pscustomobject]@{Available=$true;Status='FAIL';CpuCompressionMBps=$null;MemoryMBps=$null;Error=$_.Exception.Message}
    }
    try {
        $stress=Invoke-SitecStress -Context $Context -RunPath $RunPath
    } catch {
        $stress=[pscustomobject]@{Status='FAIL';Error=$_.Exception.Message;CpuStress=[pscustomobject]@{Seconds=0;Threads=0;HashWorkMBps=0;Iterations=0};MemoryVerification=[pscustomobject]@{RequestedMB=0;VerifiedMB=0;Errors=[long]::MaxValue;Seconds=0};Sensors=@()}
    }
    try {
        $disk=Invoke-SitecDiskSpd -Context $Context -RunPath $RunPath
    } catch {
        $disk=[pscustomobject]@{Available=$true;Required=[bool]$Context.Settings.DiskSpd.Enabled;Status='FAIL';SequentialReadMBps=$null;SequentialWriteMBps=$null;RandomReadIOPS=$null;Error=$_.Exception.Message}
    }
    $whea=Get-SitecWheaEvents -Since $started
    [pscustomobject]@{
        StartedAt=$started.ToString('o')
        FinishedAt=(Get-Date).ToString('o')
        WinSAT=$winsat
        Stress=$stress
        DiskSpd=$disk
        WHEA=[pscustomobject]@{ Count=@($whea).Count; Events=@($whea) }
    }
}
