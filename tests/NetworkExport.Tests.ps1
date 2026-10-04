$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path ([IO.Path]::GetTempPath()) ('SitecQC-NetworkExport-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $context=[pscustomobject]@{ Settings=[pscustomobject]@{ NetworkExport=[pscustomobject]@{
        Enabled=$true
        SharePath='\\10.50.50.20\QC-Results'
        Username='QCTransfer'
        AutoExport=$true
        RetryCount=3
        RetryDelaySeconds=2
    }}}

    $defaults=Get-SitecNetworkExportSettings -Context $context -LauncherDir $temp
    if ($defaults.SharePath -ne '\\10.50.50.20\QC-Results') { throw 'Default network export path mismatch.' }
    if ($defaults.Username -ne 'QCTransfer') { throw 'Default network export username mismatch.' }
    if (-not $defaults.AutoExport) { throw 'Auto export must be enabled by default.' }

    Save-SitecNetworkExportSettings -LauncherDir $temp -Enabled $true -SharePath '\\10.50.50.20\QC-Results' -Username 'QCTransfer' -AutoExport $false -RetryCount 4 -RetryDelaySeconds 1 | Out-Null
    $saved=Get-SitecNetworkExportSettings -Context $context -LauncherDir $temp
    if ($saved.AutoExport) { throw 'Local network export override was not loaded.' }
    if ($saved.RetryCount -ne 4) { throw 'Network export retry setting was not persisted.' }

    Write-Host 'Network export settings tests passed.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
