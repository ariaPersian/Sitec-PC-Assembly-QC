#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }

$ctx=Get-SitecContext
$profile=Get-SitecProfile -Context $ctx -ProfileId 'B760-14700K-990PRO'

$diskSettings=[pscustomobject]@{
    DiskLoadMode='MaximumSafe'
    DiskTargetSizeMB=0
    DiskTargetPercentOfFree=2
    DiskTargetMinimumMB=4096
    DiskTargetMaximumMB=16384
    DiskReserveFreeMB=20480
}
$plan=Get-SitecBurnInDiskPlan -TotalMB 953000 -FreeMB 800000 -Settings $diskSettings
Assert-True ($plan.LoadMode -eq 'MaximumSafe') 'NVMe plan must be MaximumSafe.'
Assert-True ($plan.TargetSizeMB -eq 16384) "1 TB-class NVMe plan should hit the safe 16 GB cap; actual=$($plan.TargetSizeMB) MB."
Assert-True ($plan.ReserveFreeMB -eq 20480) 'NVMe plan must preserve the 20 GB free-space reserve.'

$planSmall=Get-SitecBurnInDiskPlan -TotalMB 250000 -FreeMB 100000 -Settings $diskSettings
Assert-True ($planSmall.TargetSizeMB -eq 4096) "Smaller free-space plan should use the 4 GB floor; actual=$($planSmall.TargetSizeMB) MB."

$previous=$env:SITECQC_BENCHMARK_COMPONENTS
try {
    $env:SITECQC_BENCHMARK_COMPONENTS='CPU,Disk,Graphics'
    $benchmark=[pscustomobject]@{
        Selection=@('CPU','Disk','Graphics')
        BurnIn=[pscustomobject]@{
            Status='PASS'
            CpuStress=[pscustomobject]@{Enabled=$true;Status='PASS';ThreadCoveragePercent=100}
            MemoryVerification=[pscustomobject]@{Enabled=$false;Status='SKIPPED';Errors=0}
            DiskStress=[pscustomobject]@{Enabled=$true;Status='PASS';ReadMBps=3500}
            GraphicsStress=[pscustomobject]@{Enabled=$true;Required=$true;Status='PASS'}
            Utilization=[pscustomobject]@{
                CPU=[pscustomobject]@{Average=96;Peak=100;Samples=20}
                Memory=[pscustomobject]@{Average=20;Peak=25;Samples=20}
                Disk=[pscustomobject]@{Average=92;Peak=100;Samples=20}
                GPU=[pscustomobject]@{Average=82;Peak=97;Samples=20}
            }
        }
        Stress=$null
        WHEA=[pscustomobject]@{Count=0;Events=@()}
        WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuStatus='PASS';MemoryStatus='SKIPPED';CpuCompressionMBps=500;MemoryMBps=$null}
        DiskSpd=[pscustomobject]@{Available=$true;Required=$true;Status='PASS';SequentialReadMBps=5000;SequentialWriteMBps=4200;RandomReadIOPS=150000}
    }

    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    Assert-True ($result.Status -eq 'PASS') 'Maximum-load CPU/NVMe/GPU fixture should PASS.'
    foreach($name in @('CPU logical-processor coverage','CPU average load during burn-in','CPU peak load during burn-in','Disk average active time during burn-in','Disk peak active time during burn-in','GPU average load during burn-in','GPU peak load during burn-in')){
        Assert-True ([bool]($result.Checks | Where-Object Name -eq $name)) "Missing maximum-load gate: $name"
    }

    $benchmark.BurnIn.Utilization.Disk.Average=50
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    Assert-True ($result.Status -eq 'FAIL') 'Under-loaded NVMe must fail the maximum-load policy.'
    $benchmark.BurnIn.Utilization.Disk.Average=92

    $benchmark.BurnIn.Utilization.GPU.Peak=40
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    Assert-True ($result.Status -eq 'FAIL') 'Under-loaded required GPU must fail the maximum-load policy.'
    $benchmark.BurnIn.Utilization.GPU.Peak=97

    $benchmark.BurnIn.CpuStress.ThreadCoveragePercent=75
    $result=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    Assert-True ($result.Status -eq 'FAIL') 'Incomplete CPU logical-processor coverage must fail the maximum-load policy.'
} finally {
    $env:SITECQC_BENCHMARK_COMPONENTS=$previous
}

Write-Host 'Maximum-load CPU/RAM/NVMe/GPU policy tests passed.' -ForegroundColor Green
