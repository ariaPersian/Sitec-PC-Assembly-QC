$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName PresentationFramework
[xml]$x=Get-Content -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
$reader=New-Object System.Xml.XmlNodeReader $x
$w=[Windows.Markup.XamlReader]::Load($reader)
if (-not $w) { throw 'Main window did not load.' }

function Assert-HasControl([string]$Name) {
    if (-not $w.FindName($Name)) { throw "Expected UI control missing: $Name" }
}
function Assert-NoControl([string]$Name) {
    if ($w.FindName($Name)) { throw "Removed UI control is still present: $Name" }
}

Assert-HasControl 'TxtAssetId'
Assert-HasControl 'TxtPsuSerial'
Assert-HasControl 'TxtCpuAtpo'
Assert-HasControl 'TxtSeal1'
Assert-HasControl 'TxtProfileDisplay'

Assert-NoControl 'TxtProfile'
Assert-NoControl 'TxtOperator'
Assert-NoControl 'TxtSeal2'

$start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
if ($start -notmatch [regex]::Escape('$TxtAssetId.Add_TextChanged')) { throw 'Asset ID TextChanged synchronization handler is missing.' }
if ($start -notmatch [regex]::Escape('$TxtSeal1.Text=$TxtAssetId.Text')) { throw 'Asset ID is not mirrored into tamper seal #1.' }
if ($start -match '\$TxtSeal2\b') { throw 'Start-SitecQC still references the removed seal #2 UI field.' }
if ($start -match '\$TxtOperator\b') { throw 'Start-SitecQC still references the removed operator UI field.' }
if ($start -match '\$TxtProfile\b') { throw 'Start-SitecQC still references the removed profile input field.' }
$profileSource="'-ProfileId',(Q ([string]`$profile.ProfileId))"
if ($start -notmatch [regex]::Escape($profileSource)) { throw 'Profile ID is not sourced internally from the configured BOM profile.' }

Write-Host 'Operator workflow UI test passed.' -ForegroundColor Green
