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
function Save-ExactFailure([string]$Message,[System.Exception]$Exception,[string]$Phase) {
    $out=Join-Path $BaselineRoot 'Output'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $record=[ordered]@{
        schema='sitecqc.failure.v1'; asset_id=$AssetId; timestamp=(Get-Date).ToString('o')
        phase=$Phase; message=$Message; exception_type=if($Exception){$Exception.GetType().FullName}else{$null}
        stack_trace=if($Exception){$Exception.ToString()}else{$null}
        powershell_error=if($Error.Count -gt 0){[string]$Error[0]}else{$null}
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out ($AssetId+'-LastFailure.json')) -Encoding UTF8
}
$started=Get-Date;$exitCode=1;$runDir=$null;$phase='initialization'
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $legacyWorker),'-AssetId',(Q $AssetId),'-ProfileId',(Q $ProfileId),'-Operator',(Q $Operator),'-CaseModel',(Q $CaseModel),'-PsuModel',(Q $PsuModel),'-PsuSerial',(Q $PsuSerial),'-CpuAtpo',(Q $CpuAtpo),'-Cooler',(Q $Cooler),'-Seal1',(Q $Seal1),'-Seal2',(Q $Seal2),'-DataRoot',(Q $WorkingRoot))
if ($ContinueBenchmarkOnBomFailure) { $args += '-ContinueBenchmarkOnBomFailure' }
try {
    $phase='worker';$child=Start-Process powershell.exe -ArgumentList ($args -join ' ') -PassThru -WindowStyle Hidden -Wait;$exitCode=$child.ExitCode
    $phase='locating run';$runRoot=Join-Path $WorkingRoot ("Assets\{0}\Runs" -f $AssetId)
    if (Test-Path -LiteralPath $runRoot) {
        $runDir=Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -ge $started.AddMinutes(-1)} | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $runDir) {$runDir=Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1}
    }
    if ($runDir) {
        $resultPath=Join-Path $runDir.FullName 'result.json';$manifestPath=Join-Path $runDir.FullName 'hardware-qc-manifest.json';$sourcePdf=Join-Path $runDir.FullName 'QC-Certificate.pdf'
        if (Test-Path -LiteralPath $resultPath) {try {$result=Get-Content $resultPath -Raw -Encoding UTF8|ConvertFrom-Json;if($result.Pdf -and(Test-Path ([string]$result.Pdf))){$sourcePdf=[string]$result.Pdf};if($result.Manifest -and(Test-Path ([string]$result.Manifest))){$manifestPath=[string]$result.Manifest}}catch{Save-ExactFailure $_.Exception.Message $_ 'reading worker result'}}
        $phase='publishing PDF';$publishedPdf=$null
        if(Test-Path -LiteralPath $sourcePdf){$publishedPdf=Publish-SitecCertificate -BaselineRoot $BaselineRoot -AssetId $AssetId -SourcePdf $sourcePdf}
        $phase='publishing full JSON'
        if(Test-Path -LiteralPath $manifestPath){[void](Publish-SitecFullJson -BaselineRoot $BaselineRoot -AssetId $AssetId -ManifestPath $manifestPath -ResultPath $resultPath -CertificatePath $publishedPdf)}
        if($exitCode -ne 0){$phase='saving failure evidence';[void](Save-SitecSupportBundle -BaselineRoot $BaselineRoot -AssetId $AssetId -RunPath $runDir.FullName)}
        else{$oldFailure=Get-SitecFailureBundlePath -BaselineRoot $BaselineRoot -AssetId $AssetId;Remove-Item -LiteralPath $oldFailure -Force -ErrorAction SilentlyContinue}
    } elseif($exitCode -ne 0) {Save-ExactFailure ('QC worker exited with code '+$exitCode) $null $phase}
} catch {Save-ExactFailure $_.Exception.Message $_ $phase;throw}
finally {Remove-SitecLocalQcResidue -WorkingRoot $WorkingRoot}
exit $exitCode
