$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }

$ctx=Get-SitecContext
Assert-True ([int]$ctx.Settings.BurnIn.DurationSeconds -eq 480) 'Production burn-in duration must be 480 seconds.'
Assert-True ([int]$ctx.Settings.BurnIn.HardTimeoutGraceSeconds -eq 60) 'Burn-in watchdog grace must be 60 seconds.'
Assert-True ([int]$ctx.Settings.BurnIn.MemoryMaximumMB -le 8192) 'Production RAM allocation cap must not exceed 8192 MB on the 16 GB profile.'
Assert-True ([int]$ctx.Settings.BurnIn.MemoryReserveMB -ge 4096) 'At least 4 GB must remain reserved to avoid paging/thrash.'

$timeout=New-SitecBurnInTimeoutResult -DurationSeconds 480 -ActualSeconds 541 -Reason 'test watchdog'
Assert-True ($timeout.Status -eq 'FAIL') 'Watchdog timeout must be a FAIL.'
Assert-True ([bool]$timeout.TimedOut) 'Watchdog timeout result must be explicitly marked TimedOut.'
Assert-True ($timeout.DiskStress.Status -eq 'TIMEOUT') 'Child workload timeout must be visible in the NVMe result.'

# Real 2D Matrix scans supplied from the i7-14700K production batch.
Assert-True (Test-SitecCpuAtpoValue 'M6M71N2102883') 'Real CPU ATPO sample M6M71N2102883 must be accepted.'
Assert-True (Test-SitecCpuAtpoValue 'M6M71N2103913') 'Real CPU ATPO sample M6M71N2103913 must be accepted.'
Assert-True (-not (Test-SitecCpuAtpoValue '123')) 'Placeholder ATPO must remain rejected.'

$source=(Get-Command Invoke-SitecFullSystemBurnIn).Definition
Assert-True ($source -match 'SITECQC_BURNIN_CHILD') 'Burn-in must execute through the isolated child-process watchdog.'
Assert-True ($source -match 'taskkill\.exe') 'Watchdog must be able to terminate the child process tree.'

Write-Host 'Production watchdog and ATPO tests passed.'
