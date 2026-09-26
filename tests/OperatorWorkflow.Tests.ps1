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
Assert-HasControl 'ChkProfileComparison'
Assert-HasControl 'ChkBenchCpu'
Assert-HasControl 'ChkBenchMemory'
Assert-HasControl 'ChkBenchDisk'
Assert-HasControl 'ChkBenchGraphics'
if ($w.FindName('ChkProfileComparison').IsChecked) { throw 'Profile comparison must be OFF by default.' }
foreach ($name in @('ChkBenchCpu','ChkBenchMemory','ChkBenchDisk','ChkBenchGraphics')) {
    if (-not $w.FindName($name).IsChecked) { throw "Benchmark component is not enabled by default: $name" }
}

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
if ($start -notmatch [regex]::Escape($profileSource)) { throw 'QC recipe/profile ID is not sourced internally from the configured default profile.' }
if ($start -notmatch [regex]::Escape("if(`$ChkProfileComparison.IsChecked){`$argList += '-EnableProfileComparison'}")) { throw 'Optional profile-comparison selection is not forwarded to the QC worker.' }
if ($start -notmatch [regex]::Escape("'-BenchmarkComponents',(Q `$benchmarkCsv)")) { throw 'Selected benchmark components are not forwarded to the QC worker.' }
if ($start -notmatch [regex]::Escape("'-ContinueBenchmarkOnBomFailure'")) { throw 'GUI does not preserve benchmark execution after a BOM mismatch.' }
if ($start -notmatch [regex]::Escape("Select at least one hardware component to benchmark.")) { throw 'GUI does not reject an empty benchmark selection.' }

$iconPath=Join-Path $root 'ui\AppIcon.ico'
if (-not (Test-Path -LiteralPath $iconPath)) { throw 'Application icon is missing from the packaged UI directory.' }
if ((Get-Item -LiteralPath $iconPath).Length -lt 1024) { throw 'Application icon file is unexpectedly small.' }
if ($start -notmatch [regex]::Escape("ui\AppIcon.ico")) { throw 'WPF window icon wiring is missing.' }

$project=Get-Content -LiteralPath (Join-Path $root 'launcher\SitecQC.Launcher.csproj') -Raw -Encoding UTF8
if ($project -notmatch '<ApplicationIcon>\.\.\\ui\\AppIcon\.ico</ApplicationIcon>') { throw 'Launcher executable icon is not configured.' }

Write-Host 'Operator workflow and application icon tests passed.' -ForegroundColor Green
