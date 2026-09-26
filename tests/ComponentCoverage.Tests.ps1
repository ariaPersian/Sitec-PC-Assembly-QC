#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw $Message}
}

$ctx=Get-SitecContext
$profile=Get-SitecProfile -Context $ctx -ProfileId 'B760-14700K-990PRO'

$cpuPlan=Get-SitecCpuBurnInPlan -LogicalProcessors 28 -Settings $ctx.Settings.BurnIn
Assert-True ($cpuPlan.CoverageMode -eq 'MaximumSafe') 'CPU plan must use MaximumSafe mode.'
Assert-True ($cpuPlan.Threads -eq 28) 'CPU MaximumSafe plan must use every logical processor.'
Assert-True ($cpuPlan.ThreadCoveragePercent -eq 100) 'CPU MaximumSafe thread coverage must be 100 percent.'
Assert-True ($cpuPlan.DutyPercent -eq 100) 'CPU MaximumSafe duty must be 100 percent.'

$diskPlan=Get-SitecDiskBurnInPlan -FreeMB 800000 -Settings $ctx.Settings.BurnIn
Assert-True ($diskPlan.CoverageMode -eq 'MaximumSafe') 'NVMe plan must use MaximumSafe mode.'
Assert-True ($diskPlan.TargetSizeMB -eq 16000) 'NVMe target should scale to 2 percent of 800000 MB free space.'
Assert-True ($diskPlan.TargetSizeMB -le [int]$ctx.Settings.BurnIn.DiskTargetSizeMaximumMB) 'NVMe target exceeded configured maximum.'
Assert-True ($diskPlan.QueueDepth -ge 32) 'NVMe MaximumSafe queue depth is too low.'
Assert-True ($diskPlan.Threads -ge 4) 'NVMe MaximumSafe thread count is too low.'
Assert-True ($diskPlan.WritePercent -eq 0) 'Sustained NVMe burn-in must remain read-only to avoid unnecessary NAND wear.'
Assert-True ($diskPlan.CacheMode -eq 'UncachedWriteThrough') 'NVMe burn-in must bypass software cache.'

$diskCap=Get-SitecDiskBurnInPlan -FreeMB 1200000 -Settings $ctx.Settings.BurnIn
Assert-True ($diskCap.TargetSizeMB -eq 16384) 'NVMe MaximumSafe target-file maximum cap was not honored.'

$gpuPlan=Get-SitecGraphicsBurnInPlan -Settings $ctx.Settings.BurnIn
Assert-True ($gpuPlan.CoverageMode -eq 'MaximumSafe') 'GPU plan must use MaximumSafe mode.'
Assert-True ($gpuPlan.WorkloadMode -eq 'Direct3D-ALU') 'GPU MaximumSafe plan must use the Direct3D ALU workload.'
Assert-True ($gpuPlan.DesktopWidth -ge 1920 -and $gpuPlan.DesktopHeight -ge 1080) 'GPU MaximumSafe workload must be at least 1080p.'
Assert-True ($gpuPlan.TargetAveragePercent -ge 70) 'GPU target average must be at least 70 percent.'
Assert-True ($gpuPlan.TargetPeakPercent -ge 90) 'GPU target peak must be at least 90 percent.'

$benchmark=[pscustomobject]@{
    Selection=@('CPU','Disk','Graphics')
    BurnIn=[pscustomobject]@{
        Status='PASS'
        CpuStress=[pscustomobject]@{
            Enabled=$true;Status='PASS';CoverageMode='MaximumSafe'
            LogicalProcessors=28;Threads=28;ThreadCoveragePercent=100;DutyPercent=100
        }
        MemoryVerification=[pscustomobject]@{Enabled=$false;Status='SKIPPED';Errors=0}
        DiskStress=[pscustomobject]@{
            Enabled=$true;Status='PASS';CoverageMode='MaximumSafe'
            ReadMBps=3200;ReadIOPS=80000;AverageReadLatencyMs=0.4
        }
        GraphicsStress=[pscustomobject]@{
            Enabled=$true;Required=$true;Status='PASS';CoverageMode='MaximumSafe'
        }
        Utilization=[pscustomobject]@{
            CPU=[pscustomobject]@{Average=95;Peak=100}
            Memory=[pscustomobject]@{Average=20;Peak=25}
            Disk=[pscustomobject]@{Average=92;Peak=100}
            GPU=[pscustomobject]@{Average=78;Peak=96}
        }
    }
    Stress=$null
    WHEA=[pscustomobject]@{Count=0;Events=@()}
    WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuStatus='PASS';MemoryStatus='SKIPPED';CpuCompressionMBps=500;MemoryMBps=$null}
    DiskSpd=[pscustomobject]@{
        Available=$true;Required=$true;Status='PASS'
        SequentialReadMBps=6000;SequentialWriteMBps=5000;RandomReadIOPS=100000
    }
}

$result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
Assert-True ($result.Status -eq 'PASS') 'Healthy MaximumSafe CPU/NVMe/GPU validation did not pass.'
Assert-True (@($result.Checks | Where-Object Name -eq 'CPU logical processor coverage').Count -gt 0) 'CPU thread-coverage check is missing.'
Assert-True (@($result.Checks | Where-Object Name -eq 'CPU peak load during burn-in').Count -gt 0) 'CPU peak-load check is missing.'
Assert-True (@($result.Checks | Where-Object Name -eq 'NVMe average active time during burn-in').Count -gt 0) 'NVMe active-time check is missing.'
Assert-True (@($result.Checks | Where-Object Name -eq 'NVMe peak active time during burn-in').Count -gt 0) 'NVMe peak-active check is missing.'
Assert-True (@($result.Checks | Where-Object Name -eq 'GPU average load during burn-in').Count -gt 0) 'GPU average-load check is missing.'
Assert-True (@($result.Checks | Where-Object Name -eq 'GPU peak load during burn-in').Count -gt 0) 'GPU peak-load check is missing.'

$benchmark.BurnIn.CpuStress.ThreadCoveragePercent=75
$result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
Assert-True ($result.Status -eq 'FAIL') 'Incomplete CPU logical-processor coverage did not fail QC.'
$benchmark.BurnIn.CpuStress.ThreadCoveragePercent=100

$benchmark.BurnIn.Utilization.CPU.Average=70
$result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
Assert-True ($result.Status -eq 'FAIL') 'Low sustained CPU utilization did not fail QC.'
$benchmark.BurnIn.Utilization.CPU.Average=95

$benchmark.BurnIn.Utilization.Disk.Average=50
$result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
Assert-True ($result.Status -eq 'FAIL') 'Low sustained NVMe active time did not fail QC.'
$benchmark.BurnIn.Utilization.Disk.Average=92

$benchmark.BurnIn.Utilization.GPU.Peak=50
$result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
Assert-True ($result.Status -eq 'FAIL') 'Low GPU peak utilization did not fail QC.'
$benchmark.BurnIn.Utilization.GPU.Peak=96

$source=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZ-ProductionBurnInBounded.ps1') -Raw -Encoding UTF8
Assert-True ($source -match '-Sh') 'NVMe burn-in lost uncached/write-through DiskSpd mode.'
Assert-True ($source -match '-w0') 'NVMe sustained burn-in must remain read-only.'
Assert-True ($source -match 'd3d -aname ALU') 'GPU workload lost Direct3D ALU maximum-load mode.'
Assert-True ($source -match '-disp off') 'GPU Direct3D workload must remain off-screen.'

Write-Host 'MaximumSafe all-component coverage tests passed.' -ForegroundColor Green
