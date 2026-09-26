#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')][string]$AssetId,
    [string]$ProfileId='B760-13700K-64GB-990PRO',
    [string]$Operator=$env:USERNAME,
    [string]$CaseModel='',
    [string]$PsuModel='',
    [string]$PsuSerial='',
    [string]$CpuAtpo='',
    [string]$Cooler='',
    [string]$Seal1='',
    [string]$Seal2='',
    [string]$DataRoot='',
    [string]$BenchmarkComponents='CPU,Memory,Disk,Graphics',
    [switch]$EnableProfileComparison,
    [switch]$ContinueBenchmarkOnBomFailure
)
$ErrorActionPreference='Stop'
$allowedBenchmarkComponents=@('CPU','Memory','Disk','Graphics')
$selectedBenchmarkComponents=@($BenchmarkComponents -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$invalidBenchmarkComponents=@($selectedBenchmarkComponents | Where-Object { $_ -notin $allowedBenchmarkComponents })
if ($invalidBenchmarkComponents.Count -gt 0) { throw ('Invalid benchmark component(s): '+($invalidBenchmarkComponents -join ', ')) }
$selectedBenchmarkComponents=@($allowedBenchmarkComponents | Where-Object { $_ -in $selectedBenchmarkComponents })
if ($selectedBenchmarkComponents.Count -eq 0) { throw 'At least one benchmark component must be selected.' }
$env:SITECQC_BENCHMARK_COMPONENTS=$selectedBenchmarkComponents -join ','
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
$cancelPath=Join-Path $data 'cancel.request.json'
$env:SITECQC_CANCEL_PATH=$cancelPath
$pipelineStarted=Get-Date
$runId='{0}-{1}' -f $AssetId,(Get-Date -Format 'yyyyMMdd-HHmmss')
$assetRoot=Join-Path $data ("Assets\$AssetId")
$runPath=Join-Path $assetRoot ("Runs\$runId")
@('benchmark','photos','passmark','diagnostics','diagnostics\steps') | ForEach-Object { New-Item -ItemType Directory -Path (Join-Path $runPath $_) -Force | Out-Null }
$statusPath=Join-Path $runPath 'status.json'
$logPath=Join-Path $runPath 'worker.log'
Initialize-SitecDiagnostics -RunPath $runPath | Out-Null

function Set-WorkerStatus([string]$Stage,[int]$Percent,[string]$Message,[string]$State='RUNNING',[Nullable[double]]$RemainingSeconds=$null) {
    $now=Get-Date
    $o=[ordered]@{
        RunId=$runId;AssetId=$AssetId;Stage=$Stage;Percent=$Percent;Message=$Message;State=$State
        StartedAt=$pipelineStarted.ToString('o');UpdatedAt=$now.ToString('o')
        ElapsedSeconds=[math]::Round(($now-$pipelineStarted).TotalSeconds,1)
        RemainingSeconds=$(if($null -ne $RemainingSeconds){[math]::Round([math]::Max(0,[double]$RemainingSeconds),1)}else{$null})
        RunPath=$runPath
    }
    $tmp=$statusPath+'.tmp'
    $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $statusPath -Force
    $line="[$(Get-Date -Format 'HH:mm:ss.fff')] [$Stage] [$State] $Message"
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage $Stage -Step 'Pipeline' -Status $State -Level $(if($State -eq 'ERROR'){'ERROR'}else{'INFO'}) -Message $Message
}

$hardware=$null;$physical=$null;$identity=$null;$profileComparison=$null;$bom=$null;$benchmark=$null;$benchValidation=$null;$passmark=@();$security=$null;$report=$null;$run=$null
$runStart=$pipelineStarted

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

    $validationMessage=if($EnableProfileComparison){'Validating hardware identity and comparing detected hardware with the selected profile'}else{'Validating hardware identity; profile comparison is disabled for this run'}
    Set-WorkerStatus 'Validation' 18 $validationMessage

    $identity=Test-SitecHardwareIdentity -Hardware $hardware -Physical $physical -Profile $profile
    $duplicates=@(Find-SitecDuplicateSerials -DataRoot $data -AssetId $AssetId -Hardware $hardware -Physical $physical -Profile $profile)
    if ($duplicates.Count -gt 0) {
        $dupChecks=@($duplicates | ForEach-Object {
            New-SitecCheck -Name ("Duplicate {0} serial" -f $_.Type) -Expected 'Unique in fleet' -Actual ("{0} already registered to {1}" -f $_.Serial,$_.ExistingAssetId) -Passed $false
        })
        $identity.Checks=@($identity.Checks)+$dupChecks
        $identity.Status='FAIL'
        $identity.FailureCount=[int]$identity.FailureCount+$dupChecks.Count
    }

    if($EnableProfileComparison){
        $profileComparison=Test-SitecProfileConformance -Hardware $hardware -Physical $physical -Profile $profile
    } else {
        $profileComparison=[pscustomobject]@{
            Enabled=$false
            ProfileId=[string]$profile.ProfileId
            ProfileVersion=[string]$profile.ProfileVersion
            Status='SKIPPED'
            MismatchCount=0
            Checks=@()
        }
    }

    $profileStatus=[string]$profileComparison.Status
    $bomStatus=if([string]$identity.Status -eq 'FAIL'){'FAIL'}elseif($profileStatus -eq 'MISMATCH'){'MISMATCH'}elseif($profileStatus -eq 'SKIPPED'){'SKIPPED'}else{'PASS'}
    $bom=[pscustomobject]@{
        Status=$bomStatus
        Mode='OptionalProfileComparison'
        ProfileComparisonEnabled=[bool]$EnableProfileComparison
        BlockingStatus=[string]$identity.Status
        ConformanceStatus=$profileStatus
        BlockingFailureCount=[int]$identity.FailureCount
        MismatchCount=[int]$profileComparison.MismatchCount
        Checks=@($identity.Checks)+@($profileComparison.Checks)
    }

    Write-SitecStepResult -RunPath $runPath -Step '12-identity-validation' -Value $identity | Out-Null
    Write-SitecStepResult -RunPath $runPath -Step '13-profile-comparison' -Value $profileComparison | Out-Null
    Write-SitecStepResult -RunPath $runPath -Step '14-validation-summary' -Value $bom | Out-Null
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Validation' -Step 'Identity' -Status $identity.Status -Level $(if($identity.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("Hardware identity/integrity validation {0}; blocking failures={1}; duplicate serials={2}." -f $identity.Status,$identity.FailureCount,$duplicates.Count) -Data $identity
    $profileLevel=if($profileStatus -eq 'MISMATCH'){'WARNING'}else{'INFO'}
    $profileMessage=if($profileStatus -eq 'SKIPPED'){'Profile comparison skipped by operator selection.'}elseif($profileStatus -eq 'MISMATCH'){'Profile comparison found advisory hardware differences; this does not fail hardware QC.'}else{'Profile comparison MATCH.'}
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Validation' -Step 'ProfileComparison' -Status $profileStatus -Level $profileLevel -Message $profileMessage -Data $profileComparison

    $runStart=Get-Date
    $passmark=@(Import-SitecPassMarkEvidence -Context $context -RunPath $runPath -Since $runStart -AssetId $AssetId)
    # Benchmarks are independent from optional profile comparison. A profile
    # mismatch is advisory only; identity/integrity failures remain blocking.
    $benchmarkMessage=if($identity.Status -eq 'FAIL'){'Identity/integrity validation failed; running selected benchmarks independently'}elseif($profileStatus -eq 'MISMATCH'){'Profile mismatch recorded as advisory; running selected hardware QC normally'}elseif($profileStatus -eq 'SKIPPED'){'Profile comparison skipped; running selected performance qualification and burn-in'}else{'Profile MATCH; running selected performance qualification and burn-in'}
    Set-WorkerStatus 'Benchmark' 28 $benchmarkMessage
    $benchmark=Invoke-SitecBenchmarkSuite -Context $context -RunPath $runPath
    if (-not $benchmark.PSObject.Properties['Selection']) { $benchmark | Add-Member -NotePropertyName Selection -NotePropertyValue @($selectedBenchmarkComponents) }
    Write-SitecStepResult -RunPath $runPath -Step '50-benchmark-result' -Value $benchmark | Out-Null
    $cancelled=($benchmark.PSObject.Properties['Cancelled'] -and [bool]$benchmark.Cancelled) -or ($benchmark.BurnIn -and $benchmark.BurnIn.PSObject.Properties['Cancelled'] -and [bool]$benchmark.BurnIn.Cancelled) -or ([string]$benchmark.BurnIn.Status -eq 'CANCELLED')
    if($cancelled){
        $cancelMessage=if($benchmark.PSObject.Properties['CancellationReason'] -and -not [string]::IsNullOrWhiteSpace([string]$benchmark.CancellationReason)){[string]$benchmark.CancellationReason}else{'Benchmark cancelled by operator.'}
        $benchValidation=[pscustomobject]@{
            Status='CANCELLED'
            Checks=@([pscustomobject]@{Name='Benchmark execution';Expected='Completed';Actual='Cancelled by operator';Passed=$false;Severity='Warning';Status='CANCELLED';Message=$cancelMessage})
        }
    } else {
        $benchValidation=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    }
    Write-SitecStepResult -RunPath $runPath -Step '60-benchmark-validation' -Value $benchValidation | Out-Null
    Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Validation' -Step 'Benchmark' -Status $benchValidation.Status -Level $(if($benchValidation.Status -eq 'PASS'){'INFO'}elseif($benchValidation.Status -eq 'CANCELLED'){'WARNING'}else{'ERROR'}) -Message ("Benchmark validation completed: {0}." -f $benchValidation.Status) -Data $benchValidation

    $failureSummary=Write-SitecFailureSummary -RunPath $runPath -BomValidation $bom -BenchmarkValidation $benchValidation
    $identityStatus=[string]$identity.Status
    $profileConformanceStatus=[string]$profileComparison.Status
    $benchmarkQcStatus=if($benchValidation.Status -in @('PASS','SKIPPED')){'PASS'}elseif($benchValidation.Status -eq 'CANCELLED'){'CANCELLED'}else{'FAIL'}
    $hardwareQcStatus=if($cancelled){'CANCELLED'}elseif($identityStatus -eq 'PASS' -and $benchmarkQcStatus -eq 'PASS'){'PASS'}else{'FAIL'}
    # Compatibility aliases retained for existing Full JSON consumers.
    $bomBlockingStatus=$identityStatus
    $bomConformanceStatus=$profileConformanceStatus
    $overall=if($cancelled){'CANCELLED'}elseif($hardwareQcStatus -eq 'PASS' -and $profileConformanceStatus -eq 'MISMATCH'){'PASS_WITH_BOM_MISMATCH'}elseif($hardwareQcStatus -eq 'PASS'){'PASS'}else{'FAIL'}
    $run=[pscustomobject]@{
        SchemaVersion='1.2'
        AssetId=$AssetId
        RunId=$runId
        Operator=$Operator
        StartedAt=$runStart.ToString('o')
        CompletedAt=(Get-Date).ToString('o')
        OverallStatus=$overall
        HardwareQcStatus=$hardwareQcStatus
        IdentityStatus=$identityStatus
        BenchmarkQcStatus=$benchmarkQcStatus
        ProfileComparisonEnabled=[bool]$EnableProfileComparison
        ProfileConformanceStatus=$profileConformanceStatus
        BomConformanceStatus=$bomConformanceStatus
        BomBlockingStatus=$bomBlockingStatus
        Profile=$profile
        Physical=$physical
        Hardware=$hardware
        IdentityValidation=$identity
        ProfileComparison=$profileComparison
        BomValidation=$bom
        BenchmarkSelection=@($selectedBenchmarkComponents)
        Benchmark=$benchmark
        BenchmarkValidation=$benchValidation
        DuplicateSerials=$duplicates
        PassMarkEvidence=$passmark
        Diagnostics=[pscustomobject]@{Events=(Join-Path $runPath 'diagnostics\events.jsonl');FatalError=(Join-Path $runPath 'fatal-error.json');BurnInChildError=(Join-Path $runPath 'diagnostics\burnin-child-error.json')}
        Execution=[pscustomobject]@{
            Cancelled=$cancelled
            CancellationReason=$(if($cancelled){$cancelMessage}else{''})
            CancellationRequestPath=$cancelPath
            RuntimeError=$false
        }
        RuntimeFailure=$null
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

    if ($overall -in @('PASS','PASS_WITH_BOM_MISMATCH')) {
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
        ValidationSummary=$failureSummary
        Diagnostics=(Join-Path $runPath 'diagnostics')
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runPath 'result.json') -Encoding UTF8

    if ($overall -eq 'PASS') {
        $profileResult=if($profileConformanceStatus -eq 'SKIPPED'){'SKIPPED'}else{'MATCH'}
        Set-WorkerStatus 'Complete' 100 ("QC complete: PASS | Identity PASS | Profile comparison {0} | Benchmark PASS | HWID SHA-256: {1}" -f $profileResult,$security.HardwareIdentitySha256) 'COMPLETE' 0
    } elseif($overall -eq 'PASS_WITH_BOM_MISMATCH') {
        $mismatchNames=@($profileComparison.Checks | Where-Object Status -eq 'WARNING' | Select-Object -ExpandProperty Name)
        Set-WorkerStatus 'Complete' 100 ("QC complete: PASS | Identity PASS | Profile comparison MISMATCH (advisory): {0} | Benchmark PASS | HWID SHA-256: {1}" -f (($mismatchNames | Select-Object -First 4) -join '; '),$security.HardwareIdentitySha256) 'COMPLETE' 0
    } elseif($overall -eq 'CANCELLED') {
        Set-WorkerStatus 'Cancelled' 100 ("Benchmark cancelled by operator | Partial evidence finalized | Full JSON preserved") 'CANCELLED' 0
    } else {
        $failedNames=@($failureSummary.Items | Where-Object Status -eq 'FAIL' | Select-Object -ExpandProperty Name)
        $short=($failedNames | Select-Object -First 3) -join '; '
        Set-WorkerStatus 'Complete' 100 ("QC complete: FAIL | Causes: {0} | Exact benchmark/QC details are in the published Full JSON" -f $short) 'COMPLETE' 0
    }

    if ($overall -in @('PASS','PASS_WITH_BOM_MISMATCH')) { exit 0 } else { exit 2 }
} catch {
    $msg=$_.Exception.Message
    $fatal=[pscustomobject][ordered]@{
        Timestamp=(Get-Date).ToString('o')
        Stage='Pipeline'
        Message=$msg
        Type=$_.Exception.GetType().FullName
        FullyQualifiedErrorId=[string]$_.FullyQualifiedErrorId
        ScriptStackTrace=[string]$_.ScriptStackTrace
        Position=[string]$_.InvocationInfo.PositionMessage
        CategoryInfo=[string]$_.CategoryInfo
    }
    try { Write-SitecDiagnosticEvent -RunPath $runPath -Stage 'Fatal' -Step 'UnhandledException' -Status 'ERROR' -Level 'ERROR' -Message $msg -ErrorRecord $_ -Data $fatal } catch {}
    try {
        $fatal | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runPath 'fatal-error.json') -Encoding UTF8
        $msg | Set-Content -LiteralPath (Join-Path $runPath 'fatal-error.txt') -Encoding UTF8
    } catch {}

    # Always leave a manifest/result skeleton so CompactOutput can publish a
    # CASE-xxx-Full.json even when the QC pipeline itself crashes.
    try {
        if($null -eq $physical){$physical=[pscustomobject]@{CaseModel=$CaseModel;PsuModel=$PsuModel;PsuSerial=$PsuSerial.Trim();CpuAtpo=$CpuAtpo.Trim();Cooler=$Cooler.Trim();Seal1=$Seal1.Trim();Seal2=$Seal2.Trim()}}
        if($null -eq $identity){$identity=[pscustomobject]@{Status='ERROR';FailureCount=1;Checks=@([pscustomobject]@{Name='Identity/runtime execution';Expected='Completed';Actual=$msg;Passed=$false;Severity='Error';Status='ERROR'})}}
        if($null -eq $profileComparison){$profileComparison=[pscustomobject]@{Enabled=[bool]$EnableProfileComparison;ProfileId=[string]$profile.ProfileId;ProfileVersion=[string]$profile.ProfileVersion;Status=$(if($EnableProfileComparison){'ERROR'}else{'SKIPPED'});MismatchCount=0;Checks=@()}}
        if($null -eq $bom){$bom=[pscustomobject]@{Status='ERROR';Mode='OptionalProfileComparison';ProfileComparisonEnabled=[bool]$EnableProfileComparison;BlockingStatus='ERROR';ConformanceStatus=[string]$profileComparison.Status;BlockingFailureCount=1;MismatchCount=0;Checks=@($identity.Checks)}}
        if($null -eq $benchmark){$benchmark=[pscustomobject]@{Selection=@($selectedBenchmarkComponents);StartedAt=$runStart.ToString('o');FinishedAt=(Get-Date).ToString('o');Cancelled=$false;RuntimeError=$true;Error=$msg}}
        if($null -eq $benchValidation){$benchValidation=[pscustomobject]@{Status='ERROR';Checks=@([pscustomobject]@{Name='Benchmark/runtime execution';Expected='Completed';Actual=$msg;Passed=$false;Severity='Error';Status='ERROR'})}}
        $partialRun=[pscustomobject]@{
            SchemaVersion='1.2';AssetId=$AssetId;RunId=$runId;Operator=$Operator;StartedAt=$runStart.ToString('o');CompletedAt=(Get-Date).ToString('o');OverallStatus='ERROR'
            HardwareQcStatus='ERROR';IdentityStatus=[string]$identity.Status;BenchmarkQcStatus='ERROR';ProfileComparisonEnabled=[bool]$EnableProfileComparison;ProfileConformanceStatus=[string]$profileComparison.Status
            BomConformanceStatus=[string]$profileComparison.Status;BomBlockingStatus=[string]$identity.Status
            Profile=$profile;Physical=$physical;Hardware=$hardware;IdentityValidation=$identity;ProfileComparison=$profileComparison;BomValidation=$bom;BenchmarkSelection=@($selectedBenchmarkComponents);Benchmark=$benchmark;BenchmarkValidation=$benchValidation
            DuplicateSerials=@();PassMarkEvidence=@($passmark)
            Diagnostics=[pscustomobject]@{Events=(Join-Path $runPath 'diagnostics\events.jsonl');FatalError=(Join-Path $runPath 'fatal-error.json');BurnInChildError=(Join-Path $runPath 'diagnostics\burnin-child-error.json')}
            Execution=[pscustomobject]@{Cancelled=$false;CancellationReason='';CancellationRequestPath=$cancelPath;RuntimeError=$true}
            RuntimeFailure=$fatal
            Security=$null
        }
        $manifest=Join-Path $runPath 'hardware-qc-manifest.json'
        $partialRun | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifest -Encoding UTF8
        [pscustomobject]@{AssetId=$AssetId;RunId=$runId;OverallStatus='ERROR';RunPath=$runPath;Manifest=$manifest;Diagnostics=(Join-Path $runPath 'diagnostics');RuntimeFailure=$fatal} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runPath 'result.json') -Encoding UTF8
    } catch {}
    try { Set-WorkerStatus 'Error' 100 $msg 'ERROR' 0 } catch {}
    Write-Error $_
    exit 1
}
