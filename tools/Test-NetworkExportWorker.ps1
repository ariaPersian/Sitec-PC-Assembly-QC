#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SharePath,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$Reason='manual'
)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$started=Get-Date
try {
    $result=Test-SitecNetworkExportConnection -SharePath $SharePath
    $payload=[ordered]@{
        Schema='SITEC-QC-NETWORK-TEST-V1'
        Reason=$Reason
        SharePath=$SharePath
        StartedAt=$started.ToString('o')
        CompletedAt=(Get-Date).ToString('o')
        Success=[bool]$result.Success
        Message=[string]$result.Message
    }
} catch {
    $payload=[ordered]@{
        Schema='SITEC-QC-NETWORK-TEST-V1'
        Reason=$Reason
        SharePath=$SharePath
        StartedAt=$started.ToString('o')
        CompletedAt=(Get-Date).ToString('o')
        Success=$false
        Message=$_.Exception.Message
    }
}

$dir=Split-Path -Parent $ResultPath
if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($payload.Success) { exit 0 } else { exit 2 }
