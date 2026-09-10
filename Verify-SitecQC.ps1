#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssetId,
    [string]$DataRoot='C:\SitecQC-Data',
    [string]$CpuAtpo='',
    [string]$PsuSerial='',
    [string]$Seal1='',
    [string]$Seal2=''
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$baselinePath=Join-Path $DataRoot ("Assets\$AssetId\Baseline\hardware-qc-manifest.json")
if (-not (Test-Path -LiteralPath $baselinePath)) { throw "Baseline not found for $AssetId: $baselinePath" }
$baseline=Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
$current=Get-SitecHardwareInventory
$checks=New-Object System.Collections.Generic.List[object]
function AddCompare([string]$name,$old,$now) {
    $a=([string]$old).Trim().ToUpperInvariant(); $b=([string]$now).Trim().ToUpperInvariant()
    $checks.Add([pscustomobject]@{ Component=$name; Baseline=$old; Current=$now; Status=if($a -eq $b){'MATCH'}else{'CHANGED'} })
}
AddCompare 'Motherboard model' $baseline.Hardware.Motherboard.Model $current.Motherboard.Model
AddCompare 'Motherboard serial' $baseline.Hardware.Motherboard.SerialNumber $current.Motherboard.SerialNumber
AddCompare 'CPU model' $baseline.Hardware.CPU.Model $current.CPU.Model
AddCompare 'CPU ProcessorId' $baseline.Hardware.CPU.ProcessorId $current.CPU.ProcessorId
AddCompare 'RAM serial set' ((@($baseline.Hardware.Memory | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|') ((@($current.Memory | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|')
AddCompare 'RAM part set' ((@($baseline.Hardware.Memory | Select-Object -ExpandProperty PartNumber) | Sort-Object) -join '|') ((@($current.Memory | Select-Object -ExpandProperty PartNumber) | Sort-Object) -join '|')
AddCompare 'Storage serial set' ((@($baseline.Hardware.Storage | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|') ((@($current.Storage | Select-Object -ExpandProperty SerialNumber) | Sort-Object) -join '|')
AddCompare 'Storage model set' ((@($baseline.Hardware.Storage | Select-Object -ExpandProperty Model) | Sort-Object) -join '|') ((@($current.Storage | Select-Object -ExpandProperty Model) | Sort-Object) -join '|')
AddCompare 'BIOS version' $baseline.Hardware.BIOS.Version $current.BIOS.Version
if ($CpuAtpo) { AddCompare 'CPU ATPO' $baseline.Physical.CpuAtpo $CpuAtpo }
if ($PsuSerial) { AddCompare 'PSU serial' $baseline.Physical.PsuSerial $PsuSerial }
if ($Seal1) { AddCompare 'Seal #1' $baseline.Physical.Seal1 $Seal1 }
if ($Seal2) { AddCompare 'Seal #2' $baseline.Physical.Seal2 $Seal2 }
$changed=@($checks | Where-Object Status -eq 'CHANGED')
$result=[pscustomobject]@{ AssetId=$AssetId; VerifiedAt=(Get-Date).ToString('o'); Status=if($changed.Count -eq 0){'MATCH'}else{'CHANGED'}; BaselineManifest=$baselinePath; Checks=@($checks) }
$outDir=Join-Path $DataRoot ("Assets\$AssetId\Verifications\"+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$out=Join-Path $outDir 'verification.json'; $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $out -Encoding UTF8
$result.Checks | Format-Table -AutoSize
Write-Host "Verification status: $($result.Status)" -ForegroundColor $(if($result.Status -eq 'MATCH'){'Green'}else{'Red'})
Write-Host "Saved: $out"
if ($result.Status -eq 'MATCH') { exit 0 } else { exit 3 }
