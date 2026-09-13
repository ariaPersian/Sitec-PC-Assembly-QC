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
    [string]$DataRoot='',
    [switch]$ContinueBenchmarkOnBomFailure
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$context=Get-SitecContext -DataRoot $DataRoot
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot=Get-SitecAssetDataRoot -AssetId $AssetId -BaseDataRoot ([string]$context.Settings.DataRoot)
    $context=Get-SitecContext -DataRoot $DataRoot
}
$profile=Get-SitecProfile -Context $context -ProfileId $ProfileId
if ([string]::IsNullOrWhiteSpace($CaseModel)) { $CaseModel=[string]$profile.Expected.CaseModel }
if ([string]::IsNullOrWhiteSpace($PsuModel)) { $PsuModel=[string]$profile.Expected.PsuModel }
if ([string]::IsNullOrWhiteSpace($Cooler)) { $Cooler=[string]$profile.Expected.CpuCoolerModel }

$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Sitec QC must run as Administrator.' }

$data=[string]$context.Settings.DataRoot
New-Item -ItemType Directory -Path $data -Force | Out-Null
$runId='{0}-{1}' -f $AssetId,(Get-Date -Format 'yyyyMMdd-HHmmss')
$assetRoot=Join-Path $data ("Assets\$AssetId")
$runPath=Join-Path $assetRoot ("Runs\$runId")
@('benchmark','photos','passmark','diagnostics','diagnostics\steps') | ForEach-Object { New-Item -ItemType Directory -Path (Join-Path $runPath $_) -Force | Out-Null }
$statusPath=Join-Path $runPath 'status.json'
$logPath=Join-Path $runPath 'worker.log'
Initialize-SitecDiagnostics -RunPath $runPath | Out-Null

function Set-WorkerStatus([string]$Stage,[int]$Percent,[string]$Message,[string]$State='RUNNING') {
    $o=[ordered]@{ RunId=$runId; AssetId=$AssetId; Stage=$Stage; Percent=$Percent; Message=$Message; State=$State; UpdatedAt=(Get-Date).ToString('o'); RunPath=$runPath }
    $tmp=$statusPath+'.tmp'
    $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $statusPath -Force
    $line="[$(Get-Date -Format 'HH:mm:ss.fff')] [$Stage] [$State] $Message"
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage $Stage -Step 'Pipeline' -Status $State -Level $(if($State -eq 'ERROR'){'ERROR'}else{'INFO'}) -Message $Message
}

try {
    Set-WorkerStatus 'Inventory' 5 'Collecting hardware inventory'
    $inventoryWatch=[Diagnostics.Stopwatch]::StartNew()
    $hardware=Get-SitecHardwareInventory
    $inventoryWatch.Stop()
    Write-SitecStepResult -RunPath $runPath -Step '10-hardware-inventory' -Value $hardware | Out-Null
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Inventory' -Step 'Hardware' -Status 'PASS' -Message ("Inventory completed in {0:N1}s: board={1}; CPU={2}; RAM modules={3}; storage devices={4}; PnP errors={5}." -f $inventoryWatch.Elapsed.TotalSeconds,$hardware.Motherboard.Model,$hardware.CPU.Model,@($hardware.Memory).Count,@($hardware.Storage).Count,@($hardware.PnPErrors).Count)

    $physical=[pscustomobject]@{
        CaseModel=$CaseModel
        PsuModel=$PsuModel
        PsuSerial=$PsuSerial.Trim()
        CpuAtpo=$CpuAtpo.Trim()
        Cooler=$Cooler.Trim()
        Seal1=$Seal1.Trim()
        Seal2=$Seal2.Trim()
    }
    Write-SitecStepResult -RunPath $runPath -Step '11-physical-identity' -Value $physical | Out-Null

    Set-WorkerStatus 'Validation' 18 'Validating expected BOM and serial identity'
    $bom=Test-SitecExpectedBom -Hardware $hardware -Physical $physical -Profile $profile
    $duplicates=@(Find-SitecDuplicateSerials -DataRoot $data -AssetId $AssetId -Hardware $hardware -Physical $physical -Profile $profile)
    if ($duplicates.Count -gt 0) {
        $dupChecks=@($duplicates | ForEach-Object {
            New-SitecCheck -Name ("Duplicate {0} serial" -f $_.Type) -Expected 'Unique in fleet' -Actual ("{0} already registered to {1}" -f $_.Serial,$_.ExistingAssetId) -Passed $false
        })
        $bom.Checks=@($bom.Checks)+$dupChecks
        $bom.Status='FAIL'
    }
    Write-SitecStepResult -RunPath $runPath -Step '12-bom-validation' -Value $bom | Out-Null
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Validation' -Step 'BOM' -Status $bom.Status -Level $(if($bom.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("BOM validation {0}; checks={1}; duplicate serials={2}." -f $bom.Status,@($bom.Checks).Count,$duplicates.Count) -Data $bom

    $runStart=Get-Date
    $passmark=@(Import-SitecPassMarkEvidence -Context $context -RunPath $runPath -Since $runStart -AssetId $AssetId)
    if ($bom.Status -eq 'PASS' -or $ContinueBenchmarkOnBomFailure) {
        Set-WorkerStatus 'Benchmark' 28 'Running performance qualification and concurrent full-system burn-in'
        $benchmark=Invoke-SitecBenchmarkSuite -Context $context -RunPath $runPath
        Write-SitecStepResult -RunPath $runPath -Step '50-benchmark-result' -Value $benchmark | Out-Null
        $benchValidation=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
        Write-SitecStepResult -RunPath $runPath -Step '60-benchmark-validation' -Value $benchValidation | Out-Null
        Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Validation' -Step 'Benchmark' -Status $benchValidation.Status -Level $(if($benchValidation.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("Benchmark validation completed: {0}." -f $benchValidation.Status) -Data $benchValidation
    } else {
        Set-WorkerStatus 'Benchmark' 55 'Benchmark skipped because expected BOM validation failed'
        $benchmark=[pscustomobject]@{
            StartedAt=$null;FinishedAt=$null
            WinSAT=[pscustomobject]@{Available=$false;Status='SKIPPED';CpuCompressionMBps=$null;MemoryMBps=$null}
            Stress=[pscustomobject]@{Status='SKIPPED';CpuStress=[pscustomobject]@{Seconds=0;Threads=0;HashWorkMBps=0;Iterations=0};MemoryVerification=[pscustomobject]@{RequestedMB=0;VerifiedMB=0;Errors=0;Seconds=0};Sensors=@()}
            DiskSpd=[pscustomobject]@{Available=$false;Required=$false;Status='SKIPPED';SequentialReadMBps=$null;SequentialWriteMBps=$null;RandomReadIOPS=$null}
            WHEA=[pscustomobject]@{Count=0;Events=@()}
        }
        $benchValidation=[pscustomobject]@{Status='SKIPPED';Checks=@(New-SitecCheck -Name 'Benchmark suite' -Expected 'BOM PASS before benchmark' -Actual 'Skipped because BOM failed' -Passed $false -Severity 'Warning')}
    }

    $failureSummary=Write-SitecFailureSummary -RunPath $runPath -BomValidation $bom -BenchmarkValidation $benchValidation
    $overall=if ($bom.Status -eq 'PASS' -and ($benchValidation.Status -eq 'PASS' -or $benchValidation.Status -eq 'SKIPPED')) {'PASS'} else {'FAIL'}
    $run=[pscustomobject]@{
        SchemaVersion='1.2'
        AssetId=$AssetId
        RunId=$runId
        Operator=$Operator
        StartedAt=$runStart.ToString('o')
        CompletedAt=(Get-Date).ToString('o')
        OverallStatus=$overall
        Profile=$profile
        Physical=$physical
        Hardware=$hardware
        BomValidation=$bom
        Benchmark=$benchmark
        BenchmarkValidation=$benchValidation
        DuplicateSerials=$duplicates
        PassMarkEvidence=$passmark
        Diagnostics=[pscustomobject]@{Events=(Join-Path $runPath 'diagnostics\events.jsonl');ProcessLog=(Join-Path $runPath 'diagnostics\process.log');FailureSummary=(Join-Path $runPath 'failure-summary.json')}
        Security=$null
    }

    Set-WorkerStatus 'Evidence' 82 'Writing manifest and calculating stable hardware identity'
    $manifest=Join-Path $runPath 'hardware-qc-manifest.json'
    $run | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $security=Protect-SitecManifest -ManifestPath $manifest -Context $context
    $run.Security=$security
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Evidence' -Step 'Manifest' -Status 'PASS' -Message ("Manifest written. Hardware Identity SHA-256={0}; Manifest SHA-256={1}." -f $security.HardwareIdentitySha256,$security.Sha256)

    Set-WorkerStatus 'Report' 90 'Generating customer HTML/PDF certificate'
    $report=New-SitecCustomerReport -Run $run -RunPath $runPath -Context $context
    Write-SitecEvidenceHashes -RunPath $runPath | Out-Null
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Report' -Step 'Certificate' -Status 'PASS' -Message ("Certificate generated. HTML={0}; PDF={1}." -f $report.HtmlPath,$report.PdfPath)

    if ($overall -eq 'PASS') {
        $baselineRoot=Join-Path $assetRoot 'Baseline'
        $baselineManifest=Join-Path $baselineRoot 'hardware-qc-manifest.json'
        if (-not (Test-Path -LiteralPath $baselineManifest)) {
            New-Item -ItemType Directory -Path $baselineRoot -Force | Out-Null
            Copy-Item -LiteralPath $manifest -Destination $baselineManifest
            Copy-Item -LiteralPath ([IO.Path]::ChangeExtension($manifest,'.sha256')) -Destination (Join-Path $baselineRoot 'hardware-qc-manifest.sha256') -ErrorAction SilentlyContinue
            $identityText=Join-Path $runPath 'hardware-identity.txt';$identitySha=Join-Path $runPath 'hardware-identity.sha256'
            if (Test-Path -LiteralPath $identityText) { Copy-Item -LiteralPath $identityText -Destination (Join-Path $baselineRoot 'hardware-identity.txt') -Force }
            if (Test-Path -LiteralPath $identitySha) { Copy-Item -LiteralPath $identitySha -Destination (Join-Path $baselineRoot 'hardware-identity.sha256') -Force }
            if ($security.Signed) {
                Copy-Item -LiteralPath $security.SignaturePath -Destination (Join-Path $baselineRoot 'hardware-qc-manifest.json.sig')
                Copy-Item -LiteralPath $security.CertificatePath -Destination (Join-Path $baselineRoot 'hardware-qc-manifest.json.cer')
            }
            Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Evidence' -Step 'Baseline' -Status 'PASS' -Message 'Initial PASS baseline created for this asset.'
        }
    }

    Update-SitecFleetIndex -DataRoot $data -Run $run
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Evidence' -Step 'FleetIndex' -Status 'PASS' -Message 'Fleet serial and run indexes updated.'

    $result=[pscustomobject]@{
        AssetId=$AssetId;RunId=$runId;OverallStatus=$overall;RunPath=$runPath
        HardwareIdentitySha256=$security.HardwareIdentitySha256;ManifestSha256=$security.Sha256
        Manifest=$manifest;Html=$report.HtmlPath;Pdf=$report.PdfPath
        FailureSummary=(Join-Path $runPath 'failure-summary.json')
        Diagnostics=(Join-Path $runPath 'diagnostics')
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runPath 'result.json') -Encoding UTF8

    if ($overall -eq 'PASS') {
        Set-WorkerStatus 'Complete' 100 ("QC complete: PASS | HWID SHA-256: {0}" -f $security.HardwareIdentitySha256) 'COMPLETE'
    } else {
        $failedNames=@($failureSummary.Items | Where-Object Status -eq 'FAIL' | Select-Object -ExpandProperty Name)
        $short=($failedNames | Select-Object -First 3) -join '; '
        Set-WorkerStatus 'Complete' 100 ("QC complete: FAIL | Causes: {0} | See failure-summary.json and diagnostics\process.log" -f $short) 'COMPLETE'
    }

    if ($overall -eq 'PASS') { exit 0 } else { exit 2 }
} catch {
    $msg=$_.Exception.Message
    try { Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Fatal' -Step 'UnhandledException' -Status 'ERROR' -Level 'ERROR' -Message $msg -ErrorRecord $_ } catch {}
    try { Set-WorkerStatus 'Error' 100 $msg 'ERROR' } catch {}
    try {
        $fatal=[pscustomobject]@{Timestamp=(Get-Date).ToString('o');Message=$msg;Type=$_.Exception.GetType().FullName;FullyQualifiedErrorId=$_.FullyQualifiedErrorId;ScriptStackTrace=$_.ScriptStackTrace;Position=$_.InvocationInfo.PositionMessage}
        $fatal | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runPath 'fatal-error.json') -Encoding UTF8
        $msg | Set-Content -LiteralPath (Join-Path $runPath 'fatal-error.txt') -Encoding UTF8
    } catch {}
    Write-Error $_
    exit 1
}
