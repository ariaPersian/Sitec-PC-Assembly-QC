#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }

$ctx=Get-SitecContext
$profile=Get-SitecProfile -Context $ctx -ProfileId 'B760-14700K-990PRO'
Assert-True ([string]$profile.BomPolicy.Mode -eq 'Advisory') 'Production profile must use advisory BOM conformance.'

$hardware=[pscustomobject]@{
    Motherboard=[pscustomobject]@{Manufacturer='ASUSTeK COMPUTER INC.';Model='TUF GAMING B760-PLUS WIFI';SerialNumber='250860932401405'}
    CPU=[pscustomobject]@{Model='13th Gen Intel(R) Core(TM) i7-13700K';Cores=16;LogicalProcessors=24}
    MemoryTotalGB=64
    Memory=@(
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='5D49E7F8'},
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='7349E7F8'},
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='7449E7F8'},
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='3F49E7F8'}
    )
    Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';FriendlyName='Samsung SSD 990 PRO 1TB';SerialNumber='SSD001';SizeGB=931.51})
    Graphics=@([pscustomobject]@{Name='Intel(R) UHD Graphics'})
    PnPErrors=@()
}
$physical=[pscustomobject]@{
    CaseModel=[string]$profile.Expected.CaseModel
    PsuModel=[string]$profile.Expected.PsuModel
    Cooler=[string]$profile.Expected.CpuCoolerModel
    CpuAtpo='5675675675';PsuSerial='3423423423';Seal1='PC-A0AD9FDAB3CC';Seal2=''
}

$result=Test-SitecExpectedBom -Hardware $hardware -Physical $physical -Profile $profile
Assert-True ($result.Status -eq 'MISMATCH') "Expected advisory MISMATCH for 13700K/64GB test fixture; actual=$($result.Status)."
Assert-True ($result.BlockingStatus -eq 'PASS') 'Advisory configuration differences must not become blocking failures.'
Assert-True ($result.ConformanceStatus -eq 'MISMATCH') 'Conformance status must explicitly report MISMATCH.'
$cpu=($result.Checks | Where-Object Name -eq 'CPU model' | Select-Object -First 1)
$ram=($result.Checks | Where-Object Name -eq 'RAM total' | Select-Object -First 1)
Assert-True ($cpu.Status -eq 'WARNING' -and $cpu.Severity -eq 'Warning') 'CPU profile difference must be advisory.'
Assert-True ($ram.Status -eq 'WARNING' -and $ram.Severity -eq 'Warning') 'RAM capacity profile difference must be advisory.'

$hardware.Motherboard.SerialNumber=''
$blocked=Test-SitecExpectedBom -Hardware $hardware -Physical $physical -Profile $profile
Assert-True ($blocked.Status -eq 'FAIL') 'Missing required motherboard serial must remain blocking.'
Assert-True ($blocked.BlockingStatus -eq 'FAIL') 'Blocking identity failure was not preserved.'

Assert-True ((Get-SitecStatusClass 'PASS_WITH_BOM_MISMATCH') -eq 'pass') 'PASS_WITH_BOM_MISMATCH must render as hardware PASS.'
Assert-True ((Get-SitecStatusClass 'MISMATCH') -eq 'warn') 'BOM MISMATCH must render as advisory/warning.'

$watchdog=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZ-BurnInWatchdog.ps1') -Raw -Encoding UTF8
Assert-True ($watchdog -notmatch 'if\(Test-SitecCancellationRequested -and') 'PowerShell cancellation predicate still contains the invalid -and parameter form.'
Assert-True ($watchdog -match 'if\(\(Test-SitecCancellationRequested\) -and') 'Fixed cancellation predicate is missing.'

$worker=Get-Content -LiteralPath (Join-Path $root 'Invoke-SitecQC.ps1') -Raw -Encoding UTF8
Assert-True ($worker -match 'PASS_WITH_BOM_MISMATCH') 'Worker does not preserve the split hardware/BOM result.'
Assert-True ($worker -match 'HardwareQcStatus') 'Worker does not persist HardwareQcStatus.'
Assert-True ($worker -match 'BomConformanceStatus') 'Worker does not persist BomConformanceStatus.'

Write-Host 'Advisory BOM conformance and watchdog regression tests passed.' -ForegroundColor Green
