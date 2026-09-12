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
    [Parameter(Mandatory)][string]$BaselineRoot,
    [string]$WorkingRoot='',
    [switch]$ContinueBenchmarkOnBomFailure
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$layout=Initialize-SitecBaselineLayout -BaselineRoot $BaselineRoot
if ([string]::IsNullOrWhiteSpace($WorkingRoot)) { $WorkingRoot=New-SitecWorkingRoot }
New-Item -ItemType Directory -Path $WorkingRoot -Force | Out-Null
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

        $publishedPdf=$null
        if (Test-Path -LiteralPath $sourcePdf) {
            $publishedPdf=Publish-SitecCertificate -BaselineRoot $BaselineRoot -AssetId $AssetId -SourcePdf $sourcePdf
        }
        if (Test-Path -LiteralPath $manifestPath) {
            [void](Publish-SitecBaselineJson -BaselineRoot $BaselineRoot -AssetId $AssetId -ManifestPath $manifestPath -CertificatePath $publishedPdf)
        }
        if ($exitCode -ne 0) {
            [void](Save-SitecSupportBundle -BaselineRoot $BaselineRoot -AssetId $AssetId -RunPath $runDir.FullName)
        } else {
            $oldFailure=Get-SitecFailureBundlePath -BaselineRoot $BaselineRoot -AssetId $AssetId
            Remove-Item -LiteralPath $oldFailure -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    # Benchmark XML, transient HTML, verbose logs, signatures and the full
    # manifest exist only while the run is active. Durable local output is
    # intentionally limited to PDF + compact Baseline JSON (plus LastFailure
    # only when troubleshooting a failed run).
    Remove-SitecLocalQcResidue -WorkingRoot $WorkingRoot
}

exit $exitCode
