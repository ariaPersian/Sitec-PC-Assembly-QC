#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

$settings=[pscustomobject]@{
    MemoryCoverageMode='MaximumSafe'
    MemoryTargetPercent=72
    MemoryReserveMB=4096
    MemoryReservePercent=5
    MemoryReserveMinimumMB=2048
    MemoryReserveMaximumMB=4096
    MemoryMinimumMB=2048
    MemoryMaximumMB=0
}

$cases=@(
    [pscustomobject]@{Name='16GB';TotalMB=16384;FreeMB=12288;ExpectedReserveMB=2048;MinimumAllocationMB=10200;MaximumAllocationMB=10240;MinimumExpectedUsage=87.4;MaximumExpectedUsage=87.6},
    [pscustomobject]@{Name='32GB';TotalMB=32768;FreeMB=26624;ExpectedReserveMB=2048;MinimumAllocationMB=24550;MaximumAllocationMB=24576;MinimumExpectedUsage=93.7;MaximumExpectedUsage=93.8},
    [pscustomobject]@{Name='64GB';TotalMB=65536;FreeMB=53248;ExpectedReserveMB=3277;MinimumAllocationMB=49900;MaximumAllocationMB=50000;MinimumExpectedUsage=94.9;MaximumExpectedUsage=95.1},
    [pscustomobject]@{Name='128GB';TotalMB=131072;FreeMB=122880;ExpectedReserveMB=4096;MinimumAllocationMB=118700;MaximumAllocationMB=118784;MinimumExpectedUsage=96.8;MaximumExpectedUsage=97.0}
)

foreach($case in $cases) {
    $plan=Get-SitecBurnInMemoryPlan -TotalMB $case.TotalMB -FreeMB $case.FreeMB -Settings $settings
    Assert-True ($plan.CoverageMode -eq 'MaximumSafe') "$($case.Name): coverage mode must be MaximumSafe."
    Assert-True ($plan.MaximumMode -eq 'MaximumSafe') "$($case.Name): allocation mode must be MaximumSafe."
    Assert-True ($plan.ReserveMB -eq $case.ExpectedReserveMB) "$($case.Name): unexpected reserve $($plan.ReserveMB) MB."
    Assert-True ($plan.AllocationTargetMB -ge $case.MinimumAllocationMB) "$($case.Name): allocation target is too small: $($plan.AllocationTargetMB) MB."
    Assert-True ($plan.AllocationTargetMB -le $case.MaximumAllocationMB) "$($case.Name): allocation target is unexpectedly high: $($plan.AllocationTargetMB) MB."
    Assert-True ($plan.ExpectedUsagePercent -ge $case.MinimumExpectedUsage -and $plan.ExpectedUsagePercent -le $case.MaximumExpectedUsage) "$($case.Name): unexpected expected system usage $($plan.ExpectedUsagePercent)%."
    Assert-True (($plan.FreeBeforeMB-$plan.AllocationTargetMB) -eq $plan.ReserveMB) "$($case.Name): MaximumSafe mode did not consume all safe free memory."
    Assert-True ($plan.SafeCoverageTargetMB -eq $plan.AllocationTargetMB) "$($case.Name): safe coverage target must equal the requested maximum-safe allocation."
}

$plan16=Get-SitecBurnInMemoryPlan -TotalMB 16384 -FreeMB 12288 -Settings $settings
$plan32=Get-SitecBurnInMemoryPlan -TotalMB 32768 -FreeMB 26624 -Settings $settings
$plan64=Get-SitecBurnInMemoryPlan -TotalMB 65536 -FreeMB 53248 -Settings $settings
$plan128=Get-SitecBurnInMemoryPlan -TotalMB 131072 -FreeMB 122880 -Settings $settings
Assert-True ($plan32.AllocationTargetMB -gt $plan16.AllocationTargetMB) '32 GB system did not scale above 16 GB.'
Assert-True ($plan64.AllocationTargetMB -gt $plan32.AllocationTargetMB) '64 GB system did not scale above 32 GB.'
Assert-True ($plan128.AllocationTargetMB -gt $plan64.AllocationTargetMB) '128 GB system did not scale above 64 GB.'
Assert-True ($plan64.AllocationTargetMB -gt 48000) '64 GB system is not exercising approximately 49-50 GB of RAM.'

$fixed=[pscustomobject]@{
    MemoryCoverageMode='MaximumSafe'
    MemoryTargetPercent=72
    MemoryReserveMB=4096
    MemoryReservePercent=5
    MemoryReserveMinimumMB=2048
    MemoryReserveMaximumMB=4096
    MemoryMinimumMB=2048
    MemoryMaximumMB=8192
}
$capped=Get-SitecBurnInMemoryPlan -TotalMB 65536 -FreeMB 53248 -Settings $fixed
Assert-True ($capped.MaximumMode -eq 'MaximumSafe+FixedCap') 'Positive MemoryMaximumMB must retain fixed-cap compatibility.'
Assert-True ($capped.AllocationTargetMB -eq 8192) "MaximumSafe fixed cap was not honored; actual=$($capped.AllocationTargetMB) MB."

$legacy=[pscustomobject]@{
    MemoryCoverageMode='TargetPercent'
    MemoryTargetPercent=72
    MemoryReserveMB=4096
    MemoryMinimumMB=2048
    MemoryMaximumMB=0
}
$legacyPlan=Get-SitecBurnInMemoryPlan -TotalMB 65536 -FreeMB 53248 -Settings $legacy
Assert-True ($legacyPlan.CoverageMode -eq 'TargetPercent') 'Legacy target-percent mode was not retained.'
Assert-True ($legacyPlan.ExpectedUsagePercent -ge 71.9 -and $legacyPlan.ExpectedUsagePercent -le 72.1) 'Legacy target-percent mode no longer converges to 72 percent.'

Write-Host 'Maximum-safe RAM coverage planning tests passed.' -ForegroundColor Green
