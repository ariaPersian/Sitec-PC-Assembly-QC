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
    [string]$PublicRoot='C:\SitecQC-Data',
    [switch]$ContinueBenchmarkOnBomFailure
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$layout=Initialize-SitecCompactOutput -PublicRoot $PublicRoot
$internalRoot=[string]$layout.InternalRoot
$legacyWorker=Join-Path $root 'Invoke-SitecQC.ps1'

function Q([string]$s) { '"' + ($s -replace '"','\"') + '"' }

$started=Get-Date
$args=@(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $legacyWorker),
    '-AssetId',(Q $AssetId),'-ProfileId',(Q $ProfileId),'-Operator',(Q $Operator),
    '-CaseModel',(Q $CaseModel),'-PsuModel',(Q $PsuModel),'-PsuSerial',(Q $PsuSerial),
    '-CpuAtpo',(Q $CpuAtpo),'-Cooler',(Q $Cooler),'-Seal1',(Q $Seal1),'-Seal2',(Q $Seal2),
    '-DataRoot',(Q $internalRoot)
)
if ($ContinueBenchmarkOnBomFailure) { $args += '-ContinueBenchmarkOnBomFailure' }

$child=Start-Process powershell.exe -ArgumentList ($args -join ' ') -PassThru -WindowStyle Hidden -Wait
$exitCode=$child.ExitCode

$runRoot=Join-Path $internalRoot ("Assets\{0}\Runs" -f $AssetId)
$runDir=$null
if (Test-Path -LiteralPath $runRoot) {
    $runDir=Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddMinutes(-1) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $runDir) {
        $runDir=Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
}

try {
    if ($runDir) {
        $resultPath=Join-Path $runDir.FullName 'result.json'
        $sourcePdf=Join-Path $runDir.FullName 'QC-Certificate.pdf'
        if (Test-Path -LiteralPath $resultPath) {
            try {
                $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($result.Pdf -and (Test-Path -LiteralPath ([string]$result.Pdf))) { $sourcePdf=[string]$result.Pdf }
            } catch {}
        }
        if (Test-Path -LiteralPath $sourcePdf) {
            [void](Publish-SitecCertificate -PublicRoot $PublicRoot -AssetId $AssetId -SourcePdf $sourcePdf)
        }
        if ($exitCode -ne 0) {
            [void](Save-SitecSupportBundle -AssetId $AssetId -RunPath $runDir.FullName)
        }
    }
} finally {
    # Raw benchmark XML, transient HTML, verbose logs and diagnostics are implementation details.
    # Baseline + fleet identity data stay under ProgramData; the customer-facing folder keeps only PDFs.
    Remove-SitecCompletedRuns -InternalRoot $internalRoot -AssetId $AssetId
}

exit $exitCode
