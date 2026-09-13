$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot

$invoke=Get-Content -LiteralPath (Join-Path $root 'Invoke-SitecQC.ps1') -Raw -Encoding UTF8
if ($invoke -notmatch 'Get-SitecAssetDataRoot\s+-AssetId\s+\$AssetId') {
    throw 'Direct Invoke-SitecQC.ps1 does not resolve its default DataRoot from Asset ID.'
}
if ($invoke -notmatch 'Get-SitecContext\s+-DataRoot\s+\$DataRoot') {
    throw 'Direct Invoke-SitecQC.ps1 does not rebind context to the resolved DataRoot.'
}

Write-Host 'Direct worker Asset-scoped DataRoot wiring tests passed.' -ForegroundColor Green
