$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }

$ctx=Get-SitecContext
Assert-True ([int]$ctx.Settings.BurnIn.DurationSeconds -eq 480) 'Production burn-in duration must be 480 seconds.'
Assert-True ([int]$ctx.Settings.BurnIn.FinalizeGraceSeconds -eq 20) 'Burn-in finalization grace must be 20 seconds.'
Assert-True ([int]$ctx.Settings.BurnIn.HardTimeoutGraceSeconds -eq 60) 'Burn-in watchdog grace must be 60 seconds.'
Assert-True ([string]$ctx.Settings.BurnIn.MemoryCoverageMode -eq 'MaximumSafe') 'Production RAM allocation must use MaximumSafe coverage mode.'
Assert-True ([int]$ctx.Settings.BurnIn.MemoryMaximumMB -eq 0) 'Production RAM allocation must not use a fixed capacity cap.'
Assert-True ([double]$ctx.Settings.BurnIn.MemoryReservePercent -eq 5) 'MaximumSafe RAM reserve must use the approved 5 percent scaling rule.'
Assert-True ([int]$ctx.Settings.BurnIn.MemoryReserveMinimumMB -eq 2048) 'MaximumSafe RAM reserve floor must be 2 GB.'
Assert-True ([int]$ctx.Settings.BurnIn.MemoryReserveMaximumMB -eq 4096) 'MaximumSafe RAM reserve ceiling must be 4 GB.'
Assert-True ([string]$ctx.Settings.BurnIn.CpuCoverageMode -eq 'MaximumSafe') 'CPU production mode must be MaximumSafe.'
Assert-True ([int]$ctx.Settings.BurnIn.CpuDutyPercent -eq 100) 'CPU MaximumSafe duty must be 100 percent.'
Assert-True ([string]$ctx.Settings.BurnIn.DiskCoverageMode -eq 'MaximumSafe') 'NVMe production mode must be MaximumSafe.'
Assert-True ([int]$ctx.Settings.BurnIn.DiskQueueDepth -ge 32) 'NVMe MaximumSafe queue depth must be at least 32 per thread.'
Assert-True ([int]$ctx.Settings.BurnIn.DiskTargetSizeMaximumMB -ge 16384) 'NVMe MaximumSafe target-file cap must be at least 16 GB.'
Assert-True ([string]$ctx.Settings.BurnIn.GraphicsCoverageMode -eq 'MaximumSafe') 'GPU production mode must be MaximumSafe.'
Assert-True ([bool]$ctx.Settings.BurnIn.GraphicsRequired) 'Selected GPU burn-in must be a required production gate.'
Assert-True ([string]$ctx.Settings.BurnIn.GraphicsWorkloadMode -eq 'Direct3D-ALU') 'GPU production workload must use Direct3D ALU.'
Assert-True ([double]$ctx.Settings.BurnIn.GraphicsTargetAveragePercent -ge 70) 'GPU workload target average must be at least 70 percent.'
Assert-True ([double]$ctx.Settings.BurnIn.GraphicsTargetPeakPercent -ge 90) 'GPU workload target peak must be at least 90 percent.'
$profile=Get-SitecProfile -Context $ctx -ProfileId 'B760-14700K-990PRO'
Assert-True ([double]$profile.Thresholds.MinimumBurnInMemoryPlanCoveragePercent -eq 95) 'RAM safe-allocation coverage gate must remain 95 percent.'
Assert-True ([double]$profile.Thresholds.MaximumBurnInMemoryPeakShortfallPercent -eq 5) 'RAM peak shortfall tolerance must remain 5 percentage points.'
Assert-True ([double]$profile.Thresholds.MinimumBurnInCpuThreadCoveragePercent -eq 100) 'CPU thread coverage gate must remain 100 percent.'
Assert-True ([double]$profile.Thresholds.MinimumBurnInCpuAveragePercent -ge 90) 'CPU average utilization gate must remain at least 90 percent.'
Assert-True ([double]$profile.Thresholds.MinimumBurnInDiskAverageActivePercent -ge 80) 'NVMe average-active gate must remain at least 80 percent.'
Assert-True ([double]$profile.Thresholds.MinimumBurnInGpuAveragePercent -ge 70) 'GPU average utilization gate must remain at least 70 percent.'
Assert-True ([double]$profile.Thresholds.MinimumBurnInGpuPeakPercent -ge 90) 'GPU peak utilization gate must remain at least 90 percent.'
Assert-True ([bool]$ctx.Settings.Reporting.StrictTwoPagePdf) 'Strict two-page customer PDF must be enabled.'

$timeout=New-SitecBurnInTimeoutResult -DurationSeconds 480 -ActualSeconds 541 -Reason 'test watchdog'
Assert-True ($timeout.Status -eq 'FAIL') 'Watchdog timeout must be a FAIL.'
Assert-True ([bool]$timeout.TimedOut) 'Watchdog timeout result must be explicitly marked TimedOut.'
Assert-True ($timeout.DiskStress.Status -eq 'TIMEOUT') 'Child workload timeout must be visible in the NVMe result.'

# Real 2D Matrix scans supplied from the i7-14700K production batch.
Assert-True (Test-SitecCpuAtpo -Value 'M6M71N2102883') 'Real CPU ATPO sample M6M71N2102883 must be accepted.'
Assert-True (Test-SitecCpuAtpo -Value 'M6M71N2103913') 'Real CPU ATPO sample M6M71N2103913 must be accepted.'
Assert-True (-not (Test-SitecCpuAtpo -Value '123')) 'Placeholder ATPO must remain rejected.'

$publicSource=(Get-Command Invoke-SitecFullSystemBurnIn).Definition
Assert-True ($publicSource -match 'SitecBurnInWithWatchdogCore') 'Public burn-in entry point must retain the watchdog wrapper.'
Assert-True ($publicSource -match 'Remove-SitecRuntimeTemporaryArtifacts') 'Burn-in must guarantee runtime temp cleanup.'

$watchdogSource=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZ-BurnInWatchdog.ps1') -Raw
Assert-True ($watchdogSource -match 'SITECQC_BURNIN_CHILD') 'Burn-in must execute through the isolated child-process watchdog.'
Assert-True ($watchdogSource -match 'taskkill\.exe') 'Watchdog must be able to terminate the child process tree.'

$boundedSource=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZ-ProductionBurnInBounded.ps1') -Raw
Assert-True ($boundedSource -match 'FinalizeGraceSeconds') 'Bounded burn-in must use a dedicated finalization grace window.'
Assert-True ($boundedSource -match 'WaitForExit\(0\)') 'External workload completion must be checked with finite Process.WaitForExit semantics.'
Assert-True ($boundedSource -match 'd3d -aname ALU') 'Production GPU burn-in must invoke WinSAT Direct3D ALU.'
Assert-True ($boundedSource -match 'Direct3D\|D3D') 'Completed Direct3D output must be usable as graphics completion evidence.'
Assert-True ($boundedSource -match 'SafeCoverageTargetMB') 'Burn-in result must preserve the MaximumSafe allocation target.'
Assert-True ($boundedSource -match 'BytesVerified -gt 0') 'RAM PASS must require real write/verify work.'

$reportSource=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZZZ-ReportTwoPage.ps1') -Raw
Assert-True (([regex]::Matches($reportSource,'<div class=\"sheet\">')).Count -eq 2) 'Customer report template must contain exactly two A4 sheets.'
Assert-True ($reportSource -match 'Hardware Identity SHA-256') 'Second report page must contain the stable hardware identity hash.'
Assert-True ($reportSource -match 'Manifest SHA-256') 'Second report page must contain the evidence manifest hash.'
Assert-True ($reportSource -match 'SitecQC-Edge-') 'PDF conversion must use an isolated temporary Edge profile.'

Write-Host 'Production watchdog, cleanup, ATPO and two-page report tests passed.'
