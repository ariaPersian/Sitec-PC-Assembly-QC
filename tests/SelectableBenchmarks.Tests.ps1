#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$context=Get-SitecContext
$profile=Get-SitecProfile -Context $context -ProfileId 'B760-14700K-990PRO'

$previous=$env:SITECQC_BENCHMARK_COMPONENTS
try {
    $env:SITECQC_BENCHMARK_COMPONENTS='CPU,Graphics'
    $selection=@(Get-SitecBenchmarkSelection)
    if (($selection -join ',') -ne 'CPU,Graphics') { throw "Unexpected component selection order: $($selection -join ',')" }
    if (-not (Test-SitecBenchmarkComponent -Name 'CPU')) { throw 'CPU selection was not detected.' }
    if (Test-SitecBenchmarkComponent -Name 'Memory') { throw 'Unselected Memory component was reported as selected.' }

    $benchmark=[pscustomobject]@{
        Selection=@('CPU')
        BurnIn=[pscustomobject]@{
            Status='PASS'
            CpuStress=[pscustomobject]@{Enabled=$true;Status='PASS'}
            MemoryVerification=[pscustomobject]@{Enabled=$false;Status='SKIPPED';Errors=[long]::MaxValue}
            DiskStress=[pscustomobject]@{Enabled=$false;Status='SKIPPED';ReadMBps=$null}
            GraphicsStress=[pscustomobject]@{Enabled=$false;Required=$false;Status='SKIPPED'}
            Utilization=[pscustomobject]@{
                CPU=[pscustomobject]@{Average=95;Peak=100}
                Memory=[pscustomobject]@{Average=1;Peak=1}
                Disk=[pscustomobject]@{Average=1;Peak=1}
                GPU=[pscustomobject]@{Average=1;Peak=1}
            }
        }
        Stress=$null
        WHEA=[pscustomobject]@{Count=0;Events=@()}
        WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuStatus='PASS';MemoryStatus='SKIPPED';CpuCompressionMBps=500;MemoryMBps=$null}
        DiskSpd=[pscustomobject]@{Available=$false;Required=$false;Status='SKIPPED'}
    }
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    if ($result.Status -ne 'PASS') { throw 'CPU-only benchmark validation did not pass.' }
    if (@($result.Checks | Where-Object Name -match 'Memory verification|RAM|DiskSpd|SSD|Graphics').Count -ne 0) {
        throw 'Validation emitted checks for unselected benchmark components.'
    }
    if (-not ($result.Checks | Where-Object Name -eq 'WinSAT CPU execution')) { throw 'CPU-only validation omitted the CPU qualification check.' }

    $benchmark.Selection=@('Memory')
    $benchmark.BurnIn.MemoryVerification=[pscustomobject]@{
        Enabled=$true;Status='PASS';Errors=0
        CoverageMode='MaximumSafe';AllocationCoveragePercent=100
        ExpectedSystemUsagePercent=95;SafeCoverageTargetMB=50000
    }
    $benchmark.BurnIn.Utilization.Memory=[pscustomobject]@{Average=93;Peak=94}
    $benchmark.WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuStatus='SKIPPED';MemoryStatus='PASS';CpuCompressionMBps=$null;MemoryMBps=20000}
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    if ($result.Status -ne 'PASS') { throw 'Memory-only MaximumSafe benchmark validation did not pass.' }
    if (-not ($result.Checks | Where-Object Name -eq 'Memory verification errors')) { throw 'Memory-only validation omitted RAM verification.' }
    if (-not ($result.Checks | Where-Object Name -eq 'RAM safe allocation coverage')) { throw 'Memory-only validation omitted safe-allocation coverage.' }
    $peakCheck=$result.Checks | Where-Object Name -eq 'Peak RAM use during burn-in' | Select-Object -First 1
    if (-not $peakCheck -or $peakCheck.Expected -notmatch '90%') { throw 'Memory peak validation did not use the dynamic 95%-planned / 5-point tolerance gate.' }
    if ($result.Checks | Where-Object Name -eq 'WinSAT CPU execution') { throw 'Memory-only validation incorrectly included CPU qualification.' }

    $benchmark.BurnIn.MemoryVerification.AllocationCoveragePercent=80
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    if ($result.Status -ne 'FAIL') { throw 'Insufficient MaximumSafe allocation coverage did not fail QC.' }

    # Regression: Intel/iGPU Windows counters may remain at 0% while the
    # authoritative WinSAT Direct3D workload completes successfully. Counter
    # telemetry must become an advisory warning, not a false hardware failure.
    $benchmark.Selection=@('Graphics')
    $benchmark.BurnIn.Status='PASS'
    $benchmark.BurnIn.GraphicsStress=[pscustomobject]@{
        Enabled=$true;Required=$true;Status='PASS';CoverageMode='MaximumSafe'
        WorkloadMode='Direct3D-ALU';TelemetryStatus='UNAVAILABLE'
        TelemetryReason='Windows GPU utilization counters remained at 0% while the WinSAT graphics workload completed successfully.'
    }
    $benchmark.BurnIn.Utilization.GPU=[pscustomobject]@{Average=0;Peak=0;Samples=40}
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    if ($result.Status -ne 'PASS') { throw 'Unavailable zero-only GPU telemetry incorrectly failed a successful graphics workload.' }
    $gpuTelemetry=@($result.Checks | Where-Object Name -eq 'GPU utilization telemetry')
    if ($gpuTelemetry.Count -ne 1 -or $gpuTelemetry[0].Status -ne 'WARNING') { throw 'Unavailable GPU telemetry was not recorded as one advisory warning.' }
    if (@($result.Checks | Where-Object Name -match '^GPU (average|peak) load').Count -ne 0) { throw 'Numeric GPU load thresholds were applied to unavailable counter telemetry.' }

    # Workload execution itself remains a blocking gate.
    $benchmark.BurnIn.GraphicsStress.Status='FAIL'
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    if ($result.Status -ne 'FAIL') { throw 'A failed required graphics workload did not fail QC.' }
} finally {
    $env:SITECQC_BENCHMARK_COMPONENTS=$previous
}

Write-Host 'Selectable benchmark tests passed.' -ForegroundColor Green
