#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }

$ctx=Get-SitecContext
Assert-True ([string]$ctx.Settings.DefaultProfileId -eq 'B760-13700K-64GB-990PRO') 'Default QC recipe/profile is not the current 13700K/64GB system.'
$profile=Get-SitecProfile -Context $ctx -ProfileId ([string]$ctx.Settings.DefaultProfileId)
Assert-True ([string]$profile.Expected.CpuModelContains -eq 'i7-13700K') 'Current profile CPU is not i7-13700K.'
Assert-True ([double]$profile.Expected.MemoryTotalGB -eq 64) 'Current profile RAM is not 64 GB.'

$hardware=[pscustomobject]@{
    Motherboard=[pscustomobject]@{Manufacturer='ASUSTeK COMPUTER INC.';Model='TUF GAMING B760-PLUS WIFI';SerialNumber='MB001'}
    CPU=[pscustomobject]@{Model='13th Gen Intel(R) Core(TM) i7-13700K';Cores=16;LogicalProcessors=24}
    MemoryTotalGB=64
    Memory=@(
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='RAM001'},
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='RAM002'},
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='RAM003'},
        [pscustomobject]@{Type='DDR5';ConfiguredSpeedMHz=4200;SerialNumber='RAM004'}
    )
    Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';FriendlyName='Samsung SSD 990 PRO 1TB';SerialNumber='SSD001';SizeGB=931.5})
    Graphics=@([pscustomobject]@{Name='Intel(R) UHD Graphics 770'})
    PnPErrors=@()
}
$physical=[pscustomobject]@{
    CaseModel=[string]$profile.Expected.CaseModel
    PsuModel=[string]$profile.Expected.PsuModel
    Cooler=[string]$profile.Expected.CpuCoolerModel
    CpuAtpo='ATPO13700K001'
    PsuSerial='PSU001'
    Seal1='PC-TEST'
    Seal2=''
}

$identity=Test-SitecHardwareIdentity -Hardware $hardware -Physical $physical -Profile $profile
Assert-True ($identity.Status -eq 'PASS') 'Matching reference PC did not pass blocking identity/integrity validation.'

$comparison=Test-SitecProfileConformance -Hardware $hardware -Physical $physical -Profile $profile
Assert-True ($comparison.Status -eq 'MATCH') 'Current 13700K/64GB reference PC did not match its production profile.'

$hardware.CPU.Model='13th Gen Intel(R) Core(TM) i7-13700'
$comparison=Test-SitecProfileConformance -Hardware $hardware -Physical $physical -Profile $profile
Assert-True ($comparison.Status -eq 'MISMATCH') 'Profile comparison did not report a hardware mismatch.'
Assert-True (@($comparison.Checks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Warning' }).Count -gt 0) 'Profile mismatch is not advisory.'

$identity=Test-SitecHardwareIdentity -Hardware $hardware -Physical $physical -Profile $profile
Assert-True ($identity.Status -eq 'PASS') 'A profile-only model mismatch incorrectly changed blocking identity status.'

$worker=Get-Content -LiteralPath (Join-Path $root 'Invoke-SitecQC.ps1') -Raw -Encoding UTF8
Assert-True ($worker -match '\[switch\]\$EnableProfileComparison') 'Worker does not expose optional profile comparison.'
Assert-True ($worker -match 'ProfileComparisonEnabled') 'Worker does not persist whether profile comparison was selected.'
Assert-True ($worker -match "Status='SKIPPED'") 'Worker does not explicitly record skipped profile comparison.'

[xml]$xaml=Get-Content -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
$reader=New-Object System.Xml.XmlNodeReader $xaml
$w=[Windows.Markup.XamlReader]::Load($reader)
$checkbox=$w.FindName('ChkProfileComparison')
Assert-True ($null -ne $checkbox) 'Profile-comparison checkbox is missing from the GUI.'
Assert-True (-not [bool]$checkbox.IsChecked) 'Profile comparison must be disabled by default.'

Write-Host 'Optional profile-comparison and current-system profile tests passed.' -ForegroundColor Green
