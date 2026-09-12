#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssetId,
    [string]$DataRoot='',
    [string]$CpuAtpo='',
    [string]$PsuSerial='',
    [string]$Seal1='',
    [string]$Seal2=''
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot=Get-SitecInternalDataRoot }

$baselinePath=Join-Path $DataRoot ("Assets\$AssetId\Baseline\hardware-qc-manifest.json")
if (-not (Test-Path -LiteralPath $baselinePath)) { throw "Baseline not found for ${AssetId}: $baselinePath" }
$baseline=Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$current=Get-SitecHardwareInventory
$profile=$baseline.Profile

function New-SitecCompareRow {
    param([string]$Name,$BaselineValue,$CurrentValue,[string]$Severity='Identity')
    $a=([string]$BaselineValue).Trim().ToUpperInvariant()
    $b=([string]$CurrentValue).Trim().ToUpperInvariant()
    [pscustomobject]@{
        Component=$Name
        Baseline=$BaselineValue
        Current=$CurrentValue
        Severity=$Severity
        Status=if($a -eq $b){'MATCH'}else{'CHANGED'}
    }
}

$checks=@()
$checks += New-SitecCompareRow 'Motherboard model' $baseline.Hardware.Motherboard.Model $current.Motherboard.Model 'Configuration'
$checks += New-SitecCompareRow 'Motherboard serial' $baseline.Hardware.Motherboard.SerialNumber $current.Motherboard.SerialNumber
$checks += New-SitecCompareRow 'CPU model' $baseline.Hardware.CPU.Model $current.CPU.Model 'Configuration'
$checks += New-SitecCompareRow 'CPU ProcessorId' $baseline.Hardware.CPU.ProcessorId $current.CPU.ProcessorId 'Configuration'
$checks += New-SitecCompareRow 'RAM serial set' ((@($baseline.Hardware.Memory | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|') ((@($current.Memory | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|')
$checks += New-SitecCompareRow 'RAM part set' ((@($baseline.Hardware.Memory | Select-Object -ExpandProperty PartNumber) | Sort-Object) -join '|') ((@($current.Memory | Select-Object -ExpandProperty PartNumber) | Sort-Object) -join '|') 'Configuration'

$baselineStorage=@(Get-SitecIdentityStorage -Hardware $baseline.Hardware -Profile $profile)
$currentStorage=@(Get-SitecIdentityStorage -Hardware $current -Profile $profile)
$checks += New-SitecCompareRow 'Storage serial set' ((@($baselineStorage | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|') ((@($currentStorage | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|')
$checks += New-SitecCompareRow 'Storage model set' ((@($baselineStorage | Select-Object -ExpandProperty Model) | Sort-Object) -join '|') ((@($currentStorage | Select-Object -ExpandProperty Model) | Sort-Object) -join '|') 'Configuration'
$checks += New-SitecCompareRow 'BIOS version' $baseline.Hardware.BIOS.Version $current.BIOS.Version 'Configuration'

if (-not [string]::IsNullOrWhiteSpace($CpuAtpo)) { $checks += New-SitecCompareRow 'CPU ATPO' $baseline.Physical.CpuAtpo $CpuAtpo }
if (-not [string]::IsNullOrWhiteSpace($PsuSerial)) { $checks += New-SitecCompareRow 'PSU serial' $baseline.Physical.PsuSerial $PsuSerial }
if (-not [string]::IsNullOrWhiteSpace($Seal1)) { $checks += New-SitecCompareRow 'Seal #1' $baseline.Physical.Seal1 $Seal1 }
if (-not [string]::IsNullOrWhiteSpace($Seal2)) { $checks += New-SitecCompareRow 'Seal #2' $baseline.Physical.Seal2 $Seal2 }

$changed=@($checks | Where-Object Status -eq 'CHANGED')
$identityChanged=@($changed | Where-Object Severity -eq 'Identity')
$result=[pscustomobject]@{
    AssetId=$AssetId
    VerifiedAt=(Get-Date).ToString('o')
    Status=if($identityChanged.Count -eq 0){'MATCH'}else{'CHANGED'}
    ConfigurationChanges=@($changed | Where-Object Severity -eq 'Configuration').Count
    IdentityChanges=$identityChanged.Count
    BaselineManifest=$baselinePath
    Checks=@($checks)
}

$outDir=Join-Path $DataRoot ("Assets\$AssetId\Verifications\"+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$out=Join-Path $outDir 'verification.json'
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $out -Encoding UTF8
$result.Checks | Format-Table -AutoSize
Write-Host "Verification identity status: $($result.Status)" -ForegroundColor $(if($result.Status -eq 'MATCH'){'Green'}else{'Red'})
if ($result.ConfigurationChanges -gt 0) { Write-Host "Configuration changes: $($result.ConfigurationChanges)" -ForegroundColor Yellow }
Write-Host "Saved internally: $out"
if ($result.Status -eq 'MATCH') { exit 0 } else { exit 3 }
