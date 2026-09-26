#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

$settings=[pscustomobject]@{
    MemoryTargetPercent=72
    MemoryReserveMB=4096
    MemoryMinimumMB=2048
    MemoryMaximumMB=0
}

$cases=@(
    [pscustomobject]@{Name='16GB';TotalMB=16384;FreeMB=12288;MinimumAllocationMB=7000;MaximumAllocationMB=8192},
    [pscustomobject]@{Name='32GB';TotalMB=32768;FreeMB=26624;MinimumAllocationMB=16000;MaximumAllocationMB=19000},
    [pscustomobject]@{Name='64GB';TotalMB=65536;FreeMB=53248;MinimumAllocationMB=33000;MaximumAllocationMB=37000},
    [pscustomobject]@{Name='128GB';TotalMB=131072;FreeMB=122880;MinimumAllocationMB=84000;MaximumAllocationMB=88000}
)

foreach($case in $cases) {
    $plan=Get-SitecBurnInMemoryPlan -TotalMB $case.TotalMB -FreeMB $case.FreeMB -Settings $settings
    Assert-True ($plan.MaximumMode -eq 'Dynamic') "$($case.Name): allocation mode must be Dynamic."
    Assert-True ($plan.AllocationTargetMB -ge $case.MinimumAllocationMB) "$($case.Name): allocation target is too small: $($plan.AllocationTargetMB) MB."
    Assert-True ($plan.AllocationTargetMB -le $case.MaximumAllocationMB) "$($case.Name): allocation target is unexpectedly high: $($plan.AllocationTargetMB) MB."
    Assert-True ($plan.ExpectedUsagePercent -ge 71.9 -and $plan.ExpectedUsagePercent -le 72.1) "$($case.Name): expected whole-system RAM usage should converge to about 72%; actual=$($plan.ExpectedUsagePercent)%."
    Assert-True (($plan.FreeBeforeMB-$plan.AllocationTargetMB) -ge $settings.MemoryReserveMB) "$($case.Name): configured RAM reserve would be violated."
}

$plan32=Get-SitecBurnInMemoryPlan -TotalMB 32768 -FreeMB 26624 -Settings $settings
$plan64=Get-SitecBurnInMemoryPlan -TotalMB 65536 -FreeMB 53248 -Settings $settings
$plan128=Get-SitecBurnInMemoryPlan -TotalMB 131072 -FreeMB 122880 -Settings $settings
Assert-True ($plan32.AllocationTargetMB -gt 8192) '32 GB system is still constrained by the legacy 8 GB cap.'
Assert-True ($plan64.AllocationTargetMB -gt $plan32.AllocationTargetMB) '64 GB system does not scale RAM allocation above 32 GB.'
Assert-True ($plan128.AllocationTargetMB -gt $plan64.AllocationTargetMB) '128 GB system does not scale RAM allocation above 64 GB.'

$fixed=[pscustomobject]@{
    MemoryTargetPercent=72
    MemoryReserveMB=4096
    MemoryMinimumMB=2048
    MemoryMaximumMB=8192
}
$legacy=Get-SitecBurnInMemoryPlan -TotalMB 65536 -FreeMB 53248 -Settings $fixed
Assert-True ($legacy.MaximumMode -eq 'Fixed') 'Positive MemoryMaximumMB must retain fixed-cap compatibility.'
Assert-True ($legacy.AllocationTargetMB -eq 8192) "Legacy fixed cap was not honored; actual=$($legacy.AllocationTargetMB) MB."

$pressure=Get-SitecBurnInMemoryPlan -TotalMB 65536 -FreeMB 10000 -Settings $settings
Assert-True ($pressure.AllocationTargetMB -eq 2048) 'Already-high memory pressure should use only the minimum verification allocation.'
Assert-True (($pressure.FreeBeforeMB-$pressure.AllocationTargetMB) -ge $settings.MemoryReserveMB) 'High-pressure scenario violated the safety reserve.'

Write-Host 'Capacity-aware RAM burn-in target tests passed.' -ForegroundColor Green
