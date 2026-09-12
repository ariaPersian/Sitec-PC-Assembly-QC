$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-CompactOutput-Test-'+[guid]::NewGuid().ToString('N'))
$public=Join-Path $temp 'public'
$internal=Join-Path $temp 'internal'
try {
    $legacyRun=Join-Path $public 'Assets\CASE-TEST\Runs\CASE-TEST-20260101-120000'
    $legacyBase=Join-Path $public 'Assets\CASE-TEST\Baseline'
    New-Item -ItemType Directory -Path $legacyRun,$legacyBase -Force | Out-Null
    'PDF-DATA' | Set-Content -LiteralPath (Join-Path $legacyRun 'QC-Certificate.pdf') -Encoding ASCII
    '{"AssetId":"CASE-TEST"}' | Set-Content -LiteralPath (Join-Path $legacyBase 'hardware-qc-manifest.json') -Encoding UTF8
    'AssetId,RunId,Type,Serial,Timestamp' | Set-Content -LiteralPath (Join-Path $public 'fleet-serial-index.csv') -Encoding ASCII
    'AssetId,RunId,Timestamp' | Set-Content -LiteralPath (Join-Path $public 'fleet-runs.csv') -Encoding ASCII

    $layout=Initialize-SitecCompactOutput -PublicRoot $public -InternalRoot $internal
    if (Test-Path -LiteralPath (Join-Path $public 'Assets')) { throw 'Legacy Assets tree was not removed from the public output root.' }
    if (Test-Path -LiteralPath (Join-Path $public 'fleet-serial-index.csv')) { throw 'Fleet serial index is still visible in the public output root.' }
    if (Test-Path -LiteralPath (Join-Path $public 'fleet-runs.csv')) { throw 'Fleet run index is still visible in the public output root.' }
    $published=Get-SitecPublishedCertificatePath -PublicRoot $public -AssetId 'CASE-TEST'
    if (-not (Test-Path -LiteralPath $published)) { throw 'Latest legacy PDF was not migrated into Reports.' }
    if (-not (Test-Path -LiteralPath (Join-Path $internal 'Assets\CASE-TEST\Baseline\hardware-qc-manifest.json'))) { throw 'Baseline was not retained internally.' }
    if (-not (Test-Path -LiteralPath (Join-Path $internal 'fleet-serial-index.csv'))) { throw 'Fleet serial index was not retained internally.' }

    $source=Join-Path $temp 'new.pdf'
    'NEW-PDF' | Set-Content -LiteralPath $source -Encoding ASCII
    $result=Publish-SitecCertificate -PublicRoot $public -AssetId 'CASE-TEST' -SourcePdf $source
    if ($result -ne $published) { throw 'Published certificate path is not stable.' }
    if ((Get-Content -LiteralPath $published -Raw).Trim() -ne 'NEW-PDF') { throw 'Published certificate was not replaced by the latest result.' }

    $visible=@(Get-ChildItem -LiteralPath $public -Force)
    if ($visible.Count -ne 1 -or $visible[0].Name -ne 'Reports') { throw 'Public output root contains unexpected generated items.' }

    $start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
    if ($start -notmatch 'Invoke-SitecQC-Compact\.ps1') { throw 'GUI does not use the compact worker wrapper.' }
    if ($start -notmatch 'Get-SitecPublishedCertificatePath') { throw 'GUI does not open the published PDF path.' }

    Write-Host 'Compact PDF-only output tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
