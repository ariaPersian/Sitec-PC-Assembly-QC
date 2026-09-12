#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')][string]$AssetId,
    [string]$ProfileId='B760-14700K-990PRO',
    [string]$Operator=$env:USERNAME,
    [string]$CaseModel='',
    [string]$PsuModel='',
    [string]$PsuSerial='',
    [string]$CpuAtpo='',
    [string]$Cooler='',
    [string]$Seal1='',
    [string]$Seal2='',
    [Parameter(Mandatory)][string]$ArchiveRoot,
    [string]$WorkingRoot='',
    [switch]$ContinueBenchmarkOnBomFailure
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$layout=Initialize-SitecPortableArchive -ArchiveRoot $ArchiveRoot
if ([string]::IsNullOrWhiteSpace($WorkingRoot)) { $WorkingRoot=New-SitecWorkingRoot }
New-Item -ItemType Directory -Path $WorkingRoot -Force | Out-Null
Seed-SitecWorkingState -ArchiveRoot $ArchiveRoot -WorkingRoot $WorkingRoot
$legacyWorker=Join-Path $root 'Invoke-SitecQC.ps1'

function Q([string]$s) { '"' + ($s -replace '"','\"') + '"' }

$started=Get-Date
$args=@(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $legacyWorker),
    '-AssetId',(Q $AssetId),'-ProfileId',(Q $ProfileId),'-Operator',(Q $Operator),
    '-CaseModel',(Q $CaseModel),'-PsuModel',(Q $PsuModel),'-PsuSerial',(Q $PsuSerial),
    '-CpuAtpo',(Q $CpuAtpo),'-Cooler',(Q $Cooler),'-Seal1',(Q $Seal1),'-Seal2',(Q $Seal2),
    '-DataRoot',(Q $WorkingRoot)
)
if ($ContinueBenchmarkOnBomFailure) { $args += '-ContinueBenchmarkOnBomFailure' }

$exitCode=1
$runDir=$null
try {
    $child=Start-Process powershell.exe -ArgumentList ($args -join ' ') -PassThru -WindowStyle Hidden -Wait
    $exitCode=$child.ExitCode

    $runRoot=Join-Path $WorkingRoot ("Assets\{0}\Runs" -f $AssetId)
    if (Test-Path -LiteralPath $runRoot) {
        $runDir=Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $started.AddMinutes(-1) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $runDir) {
            $runDir=Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
    }

    if ($runDir) {
        $resultPath=Join-Path $runDir.FullName 'result.json'
        $manifestPath=Join-Path $runDir.FullName 'hardware-qc-manifest.json'
        $sourcePdf=Join-Path $runDir.FullName 'QC-Certificate.pdf'
        if (Test-Path -LiteralPath $resultPath) {
            try {
                $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($result.Pdf -and (Test-Path -LiteralPath ([string]$result.Pdf))) { $sourcePdf=[string]$result.Pdf }
                if ($result.Manifest -and (Test-Path -LiteralPath ([string]$result.Manifest))) { $manifestPath=[string]$result.Manifest }
            } catch {}
        }

        $published=$null
        if (Test-Path -LiteralPath $sourcePdf) {
            $published=Publish-SitecCertificate -ArchiveRoot $ArchiveRoot -AssetId $AssetId -SourcePdf $sourcePdf
        }

        # Baselines and fleet serial indexes are durable only on the removable archive.
        Sync-SitecWorkingState -ArchiveRoot $ArchiveRoot -WorkingRoot $WorkingRoot -AssetId $AssetId

        if ((Test-Path -LiteralPath $manifestPath) -and $published) {
            try {
                $run=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                [void](Update-SitecFleetRegister -ArchiveRoot $ArchiveRoot -Run $run -CertificatePath $published)
            } catch {}
        }

        if ($exitCode -ne 0) {
            [void](Save-SitecSupportBundle -ArchiveRoot $ArchiveRoot -AssetId $AssetId -RunPath $runDir.FullName)
        }
    }
} finally {
    # All benchmark XML, transient HTML, manifests, verbose logs and runtime data are local only
    # while the test is running. Durable evidence/state has already been exported to USB.
    Remove-SitecLocalQcResidue -WorkingRoot $WorkingRoot
}

exit $exitCode
