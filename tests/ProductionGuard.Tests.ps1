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
Assert-True ($boundedSource -match 'Video Memory Throughput') 'Completed WinSAT output must be usable as graphics completion evidence.'

$reportSource=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZZZ-ReportTwoPage.ps1') -Raw
Assert-True (([regex]::Matches($reportSource,'<div class=\"sheet\">')).Count -eq 2) 'Customer report template must contain exactly two A4 sheets.'
Assert-True ($reportSource -match 'Hardware Identity SHA-256') 'Second report page must contain the stable hardware identity hash.'
Assert-True ($reportSource -match 'Manifest SHA-256') 'Second report page must contain the evidence manifest hash.'
Assert-True ($reportSource -match 'SitecQC-Edge-') 'PDF conversion must use an isolated temporary Edge profile.'

Write-Host 'Production watchdog, cleanup, ATPO and two-page report tests passed.'
