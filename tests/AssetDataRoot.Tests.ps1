$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$case001=Get-SitecAssetDataRoot -AssetId 'CASE-001' -BaseDataRoot 'C:\SitecQC-Data'
if ($case001 -ne 'C:\SitecQC-Data-001') { throw "CASE-001 data root mismatch: $case001" }

$pc200=Get-SitecAssetDataRoot -AssetId 'PC-200' -BaseDataRoot 'C:\SitecQC-Data'
if ($pc200 -ne 'C:\SitecQC-Data-200') { throw "PC-200 data root mismatch: $pc200" }

$fallback=Get-SitecAssetDataRoot -AssetId 'CASE-TEST' -BaseDataRoot 'C:\SitecQC-Data'
if ($fallback -ne 'C:\SitecQC-Data-CASE-TEST') { throw "Non-numeric Asset ID fallback mismatch: $fallback" }

$start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
if ($start -notmatch 'New-SitecWorkingRoot\s+-AssetId\s+\$asset') {
    throw 'GUI does not create the working root from the confirmed Asset ID.'
}
if ($start -notmatch 'BaseDataRoot\s+\(\[string\]\$context\.Settings\.DataRoot\)') {
    throw 'GUI does not preserve the configured SitecQC data-root base path.'
}

Write-Host 'Asset-scoped SitecQC data-root tests passed.' -ForegroundColor Green
