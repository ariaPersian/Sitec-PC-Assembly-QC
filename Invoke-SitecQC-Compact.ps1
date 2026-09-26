#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')][string]$AssetId,
    [string]$ProfileId='B760-13700K-64GB-990PRO',[string]$Operator=$env:USERNAME,[string]$CaseModel='',[string]$PsuModel='',[string]$PsuSerial='',[string]$CpuAtpo='',[string]$Cooler='',[string]$Seal1='',[string]$Seal2='',
    [string]$BenchmarkComponents='CPU,Memory,Disk,Graphics',
    [Parameter(Mandatory)][string]$BaselineRoot,[string]$WorkingRoot='', [switch]$ContinueBenchmarkOnBomFailure
)
$ErrorActionPreference='Stop';$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$null=Initialize-SitecBaselineLayout -BaselineRoot $BaselineRoot
if ([string]::IsNullOrWhiteSpace($WorkingRoot)) {$WorkingRoot=New-SitecWorkingRoot};New-Item -ItemType Directory -Path $WorkingRoot -Force|Out-Null
$cancelPath=Join-Path $WorkingRoot 'cancel.request.json'
Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
$env:SITECQC_CANCEL_PATH=$cancelPath
$legacyWorker=Join-Path $root 'Invoke-SitecQC.ps1';function Q([string]$s){'"'+($s-replace '"','\"')+'"'}
function Save-ExactFailure([string]$Message,[System.Exception]$Exception,[string]$Phase){
    $out=Join-Path $BaselineRoot 'Output';New-Item -ItemType Directory -Path $out -Force|Out-Null
    [ordered]@{schema='sitecqc.failure.v1';asset_id=$AssetId;timestamp=(Get-Date).ToString('o');phase=$Phase;message=$Message;exception_type=if($Exception){$Exception.GetType().FullName}else{$null};stack_trace=if($Exception){$Exception.ToString()}else{$null};exit_code=$script:exitCode}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out ($AssetId+'-LastFailure.json')) -Encoding UTF8
}
$started=Get-Date;$script:exitCode=1;$runDir=$null;$phase='initialization'
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $legacyWorker),'-AssetId',(Q $AssetId),'-ProfileId',(Q $ProfileId),'-Operator',(Q $Operator),'-CaseModel',(Q $CaseModel),'-PsuModel',(Q $PsuModel),'-PsuSerial',(Q $PsuSerial),'-CpuAtpo',(Q $CpuAtpo),'-Cooler',(Q $Cooler),'-Seal1',(Q $Seal1),'-Seal2',(Q $Seal2),'-BenchmarkComponents',(Q $BenchmarkComponents),'-DataRoot',(Q $WorkingRoot));if($ContinueBenchmarkOnBomFailure){$args+='-ContinueBenchmarkOnBomFailure'}
try {
    $phase='worker';$child=Start-Process powershell.exe -ArgumentList ($args-join ' ') -PassThru -WindowStyle Hidden -Wait;$script:exitCode=$child.ExitCode
    $phase='locating run';$runRoot=Join-Path $WorkingRoot ("Assets\{0}\Runs"-f $AssetId)
    if(Test-Path $runRoot){$runDir=Get-ChildItem $runRoot -Directory -ErrorAction SilentlyContinue|Where-Object {$_.LastWriteTime-ge$started.AddMinutes(-1)}|Sort-Object LastWriteTime -Descending|Select-Object -First 1;if(-not $runDir){$runDir=Get-ChildItem $runRoot -Directory -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1}}
    if($runDir){
        $resultPath=Join-Path $runDir.FullName 'result.json';$manifestPath=Join-Path $runDir.FullName 'hardware-qc-manifest.json';$sourcePdf=Join-Path $runDir.FullName 'QC-Certificate.pdf'
        if(Test-Path $resultPath){
            try {
                $result=Get-Content $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
                if($result.Pdf -and(Test-Path ([string]$result.Pdf))){$sourcePdf=[string]$result.Pdf}
                if($result.Manifest -and(Test-Path ([string]$result.Manifest))){$manifestPath=[string]$result.Manifest}
            } catch {
                throw ('Unable to read the completed QC result: '+$_.Exception.Message)
            }
        }
        $phase='publishing PDF';$publishedPdf=$null
        if(Test-Path $sourcePdf){$publishedPdf=Publish-SitecCertificate -BaselineRoot $BaselineRoot -AssetId $AssetId -SourcePdf $sourcePdf}
        $phase='publishing Full JSON';$publishedBaseline=$null;$publishedFull=$null
        if(Test-Path $manifestPath){
            # Full JSON is the authoritative machine-readable evidence and must be
            # published even when a runtime error left only a partial manifest.
            try {
                $publishedFull=Publish-SitecFullJson -BaselineRoot $BaselineRoot -AssetId $AssetId -ManifestPath $manifestPath -ResultPath $resultPath -CertificatePath $publishedPdf -BaselinePath ''
            } catch {
                $fullFallback=Get-SitecPublishedFullJsonPath -BaselineRoot $BaselineRoot -AssetId $AssetId
                $raw=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if(-not $raw.PSObject.Properties['FullExportSchema']){$raw|Add-Member -NotePropertyName FullExportSchema -NotePropertyValue 'SITEC-QC-FULL-V1'}
                $raw | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $fullFallback -Encoding UTF8
                $publishedFull=$fullFallback
            }
            try {
                $manifestObject=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if($manifestObject.Hardware -and $manifestObject.Physical -and $manifestObject.Security){
                    $publishedBaseline=Publish-SitecBaselineJson -BaselineRoot $BaselineRoot -AssetId $AssetId -ManifestPath $manifestPath -CertificatePath $publishedPdf
                }
            } catch {}
            if($publishedBaseline -and(Test-Path $publishedBaseline)){
                try {
                    # Re-publish once with the temporary Baseline filename embedded,
                    # then keep the current compact-output behavior.
                    $publishedFull=Publish-SitecFullJson -BaselineRoot $BaselineRoot -AssetId $AssetId -ManifestPath $manifestPath -ResultPath $resultPath -CertificatePath $publishedPdf -BaselinePath $publishedBaseline
                } catch {}
                Remove-Item $publishedBaseline -Force -ErrorAction SilentlyContinue
            }
        }

        if($script:exitCode -notin @(0,2)){
            $phase='saving runtime failure evidence'
            [void](Save-SitecSupportBundle -BaselineRoot $BaselineRoot -AssetId $AssetId -RunPath $runDir.FullName)
            $runtimeMessage='QC worker runtime error; exit code '+$script:exitCode
            if($publishedFull -and (Test-Path -LiteralPath $publishedFull)){
                try {
                    $fj=Get-Content -LiteralPath $publishedFull -Raw -Encoding UTF8 | ConvertFrom-Json
                    if($fj.PSObject.Properties['ErrorSummary'] -and $fj.ErrorSummary -and -not [string]::IsNullOrWhiteSpace([string]$fj.ErrorSummary.PrimaryMessage)){$runtimeMessage=[string]$fj.ErrorSummary.PrimaryMessage}
                } catch {}
            }
            Save-ExactFailure $runtimeMessage $null $phase
        } else {
            # Exit 0 = QC PASS; exit 2 = completed QC with one or more failed gates.
            # Neither is an application/runtime error, so stale runtime-failure evidence
            # must not be retained or created.
            $oldFailure=Get-SitecFailureBundlePath -BaselineRoot $BaselineRoot -AssetId $AssetId
            Remove-Item $oldFailure -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $BaselineRoot 'Output' ($AssetId+'-LastFailure.json')) -Force -ErrorAction SilentlyContinue
        }
    } elseif($script:exitCode -eq 2){
        $script:exitCode=1
        Save-ExactFailure 'QC worker reported a completed FAIL result, but its run directory could not be located.' $null 'locating run'
    } elseif($script:exitCode -ne 0){
        Save-ExactFailure ('QC worker runtime error; exit code '+$script:exitCode) $null $phase
    }
} catch {
    $script:exitCode=1
    try { Save-ExactFailure $_.Exception.Message $_ $phase } catch {}
    Write-Error $_ -ErrorAction Continue
}
finally {Remove-SitecLocalQcResidue -WorkingRoot $WorkingRoot}

if($script:exitCode -eq 0){exit 0}
if($script:exitCode -eq 2){exit 2}
exit 1
