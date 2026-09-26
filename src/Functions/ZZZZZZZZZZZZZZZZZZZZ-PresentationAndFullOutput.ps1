# Production presentation/export policy for v3.13.0.
# Raw hardware inventory remains untouched for validation, HWID and JSON evidence.
# Only customer-facing UI/PDF presentation normalizes RAM branding to Crucial.

function Get-SitecPublishedFullJsonPath {
    param([Parameter(Mandatory)][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ("{0}-Full.json" -f $AssetId)
}

function New-SitecFullErrorDetail {
    param(
        [string]$Source,[string]$Stage,[string]$Status,[string]$Severity,[string]$Name,[string]$Message,
        [string]$Expected='',[string]$Actual='',[string]$ExceptionType='',[string]$FullyQualifiedErrorId='',
        [string]$ScriptStackTrace='',[string]$PositionMessage='',[string]$Timestamp='',[string]$DiagnosticFile=''
    )
    [pscustomobject][ordered]@{
        Source=$Source;Stage=$Stage;Status=$Status;Severity=$Severity;Name=$Name;Message=$Message
        Expected=$Expected;Actual=$Actual
        ExceptionType=$ExceptionType;FullyQualifiedErrorId=$FullyQualifiedErrorId
        ScriptStackTrace=$ScriptStackTrace;PositionMessage=$PositionMessage
        Timestamp=$Timestamp;DiagnosticFile=$DiagnosticFile
    }
}

function Get-SitecFullErrorDetails {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath)

    $details=@()
    foreach ($group in @(
        [pscustomobject]@{Name='BOM';Value=$(if($Run.PSObject.Properties['BomValidation']){$Run.BomValidation}else{$null})},
        [pscustomobject]@{Name='Benchmark';Value=$(if($Run.PSObject.Properties['BenchmarkValidation']){$Run.BenchmarkValidation}else{$null})}
    )) {
        if ($null -eq $group.Value -or -not $group.Value.PSObject.Properties['Checks']) { continue }
        foreach ($check in @($group.Value.Checks | Where-Object { [string]$_.Status -ne 'PASS' })) {
            $message=if($check.PSObject.Properties['Message'] -and -not [string]::IsNullOrWhiteSpace([string]$check.Message)){[string]$check.Message}else{('{0}: expected [{1}], actual [{2}]' -f $check.Name,$check.Expected,$check.Actual)}
            $details += New-SitecFullErrorDetail -Source 'Validation' -Stage $group.Name -Status ([string]$check.Status) -Severity ([string]$check.Severity) -Name ([string]$check.Name) -Message $message -Expected ([string]$check.Expected) -Actual ([string]$check.Actual)
        }
    }

    if ($Run.PSObject.Properties['Benchmark'] -and $Run.Benchmark) {
        foreach ($name in @('WinSAT','DiskSpd','Stress','BurnIn')) {
            if (-not $Run.Benchmark.PSObject.Properties[$name] -or $null -eq $Run.Benchmark.$name) { continue }
            $candidate=$Run.Benchmark.$name
            if ($candidate.PSObject.Properties['Error'] -and -not [string]::IsNullOrWhiteSpace([string]$candidate.Error)) {
                $details += New-SitecFullErrorDetail -Source 'RuntimeResult' -Stage 'Benchmark' -Status $(if($candidate.PSObject.Properties['Status']){[string]$candidate.Status}else{'ERROR'}) -Severity 'ERROR' -Name $name -Message ([string]$candidate.Error)
            }
        }
        if($Run.Benchmark.PSObject.Properties['CancellationReason'] -and -not [string]::IsNullOrWhiteSpace([string]$Run.Benchmark.CancellationReason)){
            $details += New-SitecFullErrorDetail -Source 'Operator' -Stage 'Benchmark' -Status 'CANCELLED' -Severity 'Warning' -Name 'Cancellation' -Message ([string]$Run.Benchmark.CancellationReason)
        }
    }

    $childErrorPath=Join-Path $RunPath 'diagnostics\burnin-child-error.json'
    if (Test-Path -LiteralPath $childErrorPath) {
        try {
            $e=Get-Content -LiteralPath $childErrorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $details += New-SitecFullErrorDetail -Source 'BurnInChild' -Stage 'Benchmark/BurnIn' -Status 'ERROR' -Severity 'ERROR' -Name 'BurnInChildException' -Message ([string]$e.Message) -ExceptionType $(if($e.PSObject.Properties['ExceptionType']){[string]$e.ExceptionType}else{''}) -FullyQualifiedErrorId $(if($e.PSObject.Properties['FullyQualifiedErrorId']){[string]$e.FullyQualifiedErrorId}else{''}) -ScriptStackTrace $(if($e.PSObject.Properties['ScriptStackTrace']){[string]$e.ScriptStackTrace}else{''}) -PositionMessage $(if($e.PSObject.Properties['PositionMessage']){[string]$e.PositionMessage}else{''}) -Timestamp $(if($e.PSObject.Properties['Time']){[string]$e.Time}else{''}) -DiagnosticFile $childErrorPath
        } catch {}
    }

    $fatalPath=Join-Path $RunPath 'fatal-error.json'
    if (Test-Path -LiteralPath $fatalPath) {
        try {
            $fatal=Get-Content -LiteralPath $fatalPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $details += New-SitecFullErrorDetail -Source 'UnhandledException' -Stage 'Fatal' -Status 'ERROR' -Severity 'ERROR' -Name 'UnhandledException' -Message ([string]$fatal.Message) -ExceptionType $(if($fatal.PSObject.Properties['Type']){[string]$fatal.Type}elseif($fatal.PSObject.Properties['ExceptionType']){[string]$fatal.ExceptionType}else{''}) -FullyQualifiedErrorId $(if($fatal.PSObject.Properties['FullyQualifiedErrorId']){[string]$fatal.FullyQualifiedErrorId}else{''}) -ScriptStackTrace $(if($fatal.PSObject.Properties['ScriptStackTrace']){[string]$fatal.ScriptStackTrace}else{''}) -PositionMessage $(if($fatal.PSObject.Properties['Position']){[string]$fatal.Position}elseif($fatal.PSObject.Properties['PositionMessage']){[string]$fatal.PositionMessage}else{''}) -Timestamp $(if($fatal.PSObject.Properties['Timestamp']){[string]$fatal.Timestamp}else{''}) -DiagnosticFile $fatalPath
        } catch {}
    }

    if ($Run.PSObject.Properties['RuntimeFailure'] -and $Run.RuntimeFailure) {
        $rf=$Run.RuntimeFailure
        $msg=if($rf.PSObject.Properties['Message']){[string]$rf.Message}else{''}
        if(-not [string]::IsNullOrWhiteSpace($msg) -and -not @($details | Where-Object { $_.Source -eq 'UnhandledException' -and $_.Message -eq $msg }).Count){
            $details += New-SitecFullErrorDetail -Source 'RuntimeFailure' -Stage 'Fatal' -Status 'ERROR' -Severity 'ERROR' -Name 'RuntimeFailure' -Message $msg -ExceptionType $(if($rf.PSObject.Properties['Type']){[string]$rf.Type}else{''}) -FullyQualifiedErrorId $(if($rf.PSObject.Properties['FullyQualifiedErrorId']){[string]$rf.FullyQualifiedErrorId}else{''}) -ScriptStackTrace $(if($rf.PSObject.Properties['ScriptStackTrace']){[string]$rf.ScriptStackTrace}else{''}) -PositionMessage $(if($rf.PSObject.Properties['Position']){[string]$rf.Position}else{''}) -Timestamp $(if($rf.PSObject.Properties['Timestamp']){[string]$rf.Timestamp}else{''})
        }
    }
    @($details)
}

function Get-SitecFullExcelInventoryProjection {
    param($Run,[string]$CertificatePath='')

    $hardware=if($Run.PSObject.Properties['Hardware']){$Run.Hardware}else{$null}
    $physical=if($Run.PSObject.Properties['Physical']){$Run.Physical}else{$null}
    $memory=if($hardware -and $hardware.PSObject.Properties['Memory']){@($hardware.Memory)}else{@()}
    $storage=if($hardware -and $hardware.PSObject.Properties['Storage']){@($hardware.Storage)}else{@()}
    $ramModels=@($memory | ForEach-Object { ((@([string]$_.Manufacturer,[string]$_.PartNumber) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ').Trim() } | Where-Object { $_ }) -join ' | '
    $ramSerials=@($memory | ForEach-Object { [string]$_.SerialNumber } | Where-Object { $_ } | Sort-Object -Unique) -join ' | '
    $ssdModels=@($storage | ForEach-Object { [string]$_.Model } | Where-Object { $_ } | Sort-Object -Unique) -join ' | '
    $ssdSerials=@($storage | ForEach-Object { [string]$_.SerialNumber } | Where-Object { $_ } | Sort-Object -Unique) -join ' | '
    $benchmarkStatus=if($Run.PSObject.Properties['BenchmarkValidation'] -and $Run.BenchmarkValidation -and $Run.BenchmarkValidation.PSObject.Properties['Status']){[string]$Run.BenchmarkValidation.Status}else{''}
    $security=if($Run.PSObject.Properties['Security']){$Run.Security}else{$null}

    [pscustomobject][ordered]@{
        'PC Tag ID'=[string]$Run.AssetId
        'CPU '='';'SSD'='';'CPU Fan'='';'PSU install'='';'Motherboard Install'='';'PIN Connectors'='';'Bios Update,PXE'='';'Win10'=''
        'Benchmark'=$(if($benchmarkStatus -eq 'PASS'){[char]0x2713}else{''})
        'BenchMark Files'=$(if($CertificatePath){[IO.Path]::GetFileName($CertificatePath)}else{''})
        'Build Status'=[string]$Run.OverallStatus
        'Model and serial Registered'=$(if([string]$Run.OverallStatus -eq 'PASS'){[char]0x2713}else{''})
        'Case Model'=$(if($physical){[string]$physical.CaseModel}else{''})
        'Motherboard Model'=$(if($hardware -and $hardware.PSObject.Properties['Motherboard']){(([string]$hardware.Motherboard.Manufacturer+' '+[string]$hardware.Motherboard.Model).Trim())}else{''})
        'Box Serial No'=''
        'Motherboard Serial No'=$(if($hardware -and $hardware.PSObject.Properties['Motherboard']){[string]$hardware.Motherboard.SerialNumber}else{''})
        'CPU Model'=$(if($hardware -and $hardware.PSObject.Properties['CPU']){[string]$hardware.CPU.Model}else{''})
        'CPU ATPO'=$(if($physical){[string]$physical.CpuAtpo}else{''})
        'CPU Fan Model'=$(if($physical){[string]$physical.Cooler}else{''})
        'CPU Fan Serial No'=''
        'RAM Model'=$ramModels;'RAM Serial No'=$ramSerials
        'SSD Model'=$ssdModels;'SSD Serial No'=$ssdSerials
        'PSU Model'=$(if($physical){[string]$physical.PsuModel}else{''})
        'PSU Serial No'=$(if($physical){[string]$physical.PsuSerial}else{''})
        'Tamper Seal #1'=$(if($physical){[string]$physical.Seal1}else{''})
        'Hardware Identity SHA-256'=$(if($security -and $security.PSObject.Properties['HardwareIdentitySha256']){[string]$security.HardwareIdentitySha256}else{''})
        'Manifest SHA-256'=$(if($security -and $security.PSObject.Properties['ManifestSha256']){[string]$security.ManifestSha256}elseif($security -and $security.PSObject.Properties['Sha256']){[string]$security.Sha256}else{''})
        'QC Date'=$(if($Run.PSObject.Properties['CompletedAt']){[string]$Run.CompletedAt}else{''})
    }
}
function Publish-SitecFullJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselineRoot,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$ResultPath='',
        [string]$CertificatePath='',
        [string]$BaselinePath=''
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }
    $run=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $result=$null
    if (-not [string]::IsNullOrWhiteSpace($ResultPath) -and (Test-Path -LiteralPath $ResultPath)) {
        try { $result=Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }

    $signature=$null
    $signaturePath=Join-Path (Split-Path -Parent $ManifestPath) 'signature-verification.json'
    if (Test-Path -LiteralPath $signaturePath) {
        try { $signature=Get-Content -LiteralPath $signaturePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }

    $hwid='';$manifestHash=''
    if ($result) {
        if ($result.PSObject.Properties['HardwareIdentitySha256']) { $hwid=[string]$result.HardwareIdentitySha256 }
        if ($result.PSObject.Properties['ManifestSha256']) { $manifestHash=[string]$result.ManifestSha256 }
    }
    if ($signature) {
        if ([string]::IsNullOrWhiteSpace($hwid) -and $signature.PSObject.Properties['HardwareIdentitySha256']) { $hwid=[string]$signature.HardwareIdentitySha256 }
        if ([string]::IsNullOrWhiteSpace($manifestHash) -and $signature.PSObject.Properties['ManifestSha256']) { $manifestHash=[string]$signature.ManifestSha256 }
    }

    $security=[ordered]@{
        HardwareIdentitySchema='SITEC-HWID-V2'
        HardwareIdentitySha256=$hwid
        ManifestSha256=$manifestHash
        Signature=$signature
    }
    if ($run.PSObject.Properties['Security']) { $run.Security=[pscustomobject]$security }
    else { $run | Add-Member -NotePropertyName Security -NotePropertyValue ([pscustomobject]$security) }

    $published=[ordered]@{
        CertificateFile=$(if($CertificatePath){[IO.Path]::GetFileName($CertificatePath)}else{''})
        BaselineFile=$(if($BaselinePath){[IO.Path]::GetFileName($BaselinePath)}else{''})
        FullJsonFile=("{0}-Full.json" -f $AssetId)
    }
    if ($run.PSObject.Properties['FullExportSchema']) { $run.FullExportSchema='SITEC-QC-FULL-V1' }
    else { $run | Add-Member -NotePropertyName FullExportSchema -NotePropertyValue 'SITEC-QC-FULL-V1' }
    if ($run.PSObject.Properties['PublishedFiles']) { $run.PublishedFiles=[pscustomobject]$published }
    else { $run | Add-Member -NotePropertyName PublishedFiles -NotePropertyValue ([pscustomobject]$published) }

    $runPath=Split-Path -Parent $ManifestPath
    $errorDetails=@(Get-SitecFullErrorDetails -Run $run -RunPath $runPath)
    $primaryMessage=''
    $primaryDetail=$errorDetails | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Message) } | Select-Object -First 1
    if ($primaryDetail) { $primaryMessage=[string]$primaryDetail.Message }
    $errorSummary=[pscustomobject][ordered]@{
        HasErrors=([string]$run.OverallStatus -ne 'PASS' -or $errorDetails.Count -gt 0)
        Count=$errorDetails.Count
        PrimaryMessage=$primaryMessage
        PrimaryStage=$(if($primaryDetail){[string]$primaryDetail.Stage}else{''})
        PrimaryExceptionType=$(if($primaryDetail){[string]$primaryDetail.ExceptionType}else{''})
        Items=$errorDetails
    }
    if ($run.PSObject.Properties['ErrorSummary']) { $run.ErrorSummary=$errorSummary }
    else { $run | Add-Member -NotePropertyName ErrorSummary -NotePropertyValue $errorSummary }
    if ($run.PSObject.Properties['ErrorDetails']) { $run.ErrorDetails=$errorDetails }
    else { $run | Add-Member -NotePropertyName ErrorDetails -NotePropertyValue $errorDetails }

    $benchmarkFailureDetails=@($errorDetails | Where-Object { $_.Stage -match 'Benchmark|BurnIn' -or $_.Source -eq 'BurnInChild' })
    $benchmarkStatus=''
    $cancelled=$false
    if($run.PSObject.Properties['BenchmarkValidation'] -and $run.BenchmarkValidation -and $run.BenchmarkValidation.PSObject.Properties['Status']){$benchmarkStatus=[string]$run.BenchmarkValidation.Status}
    if($run.PSObject.Properties['Benchmark'] -and $run.Benchmark -and $run.Benchmark.PSObject.Properties['Cancelled']){$cancelled=[bool]$run.Benchmark.Cancelled}
    $benchmarkFailure=[pscustomobject][ordered]@{
        HasFailure=($benchmarkStatus -notin @('','PASS','SKIPPED') -or $benchmarkFailureDetails.Count -gt 0)
        Status=$benchmarkStatus
        Cancelled=$cancelled
        Message=$(if($benchmarkFailureDetails.Count -gt 0){[string]$benchmarkFailureDetails[0].Message}else{''})
        ExceptionType=$(if($benchmarkFailureDetails.Count -gt 0){[string]$benchmarkFailureDetails[0].ExceptionType}else{''})
        FullyQualifiedErrorId=$(if($benchmarkFailureDetails.Count -gt 0){[string]$benchmarkFailureDetails[0].FullyQualifiedErrorId}else{''})
        ScriptStackTrace=$(if($benchmarkFailureDetails.Count -gt 0){[string]$benchmarkFailureDetails[0].ScriptStackTrace}else{''})
        PositionMessage=$(if($benchmarkFailureDetails.Count -gt 0){[string]$benchmarkFailureDetails[0].PositionMessage}else{''})
        Details=$benchmarkFailureDetails
    }
    if($run.PSObject.Properties['BenchmarkFailure']){$run.BenchmarkFailure=$benchmarkFailure}else{$run|Add-Member -NotePropertyName BenchmarkFailure -NotePropertyValue $benchmarkFailure}

    $excelInventory=Get-SitecFullExcelInventoryProjection -Run $run -CertificatePath $CertificatePath
    if($run.PSObject.Properties['ExcelInventory']){$run.ExcelInventory=$excelInventory}else{$run|Add-Member -NotePropertyName ExcelInventory -NotePropertyValue $excelInventory}

    $outputRoot=Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $destination=Get-SitecPublishedFullJsonPath -BaselineRoot $BaselineRoot -AssetId $AssetId
    $run | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $destination -Encoding UTF8
    $destination
}

function Set-SitecPresentationProperty {
    param($Object,[Parameter(Mandatory)][string]$Name,$Value)
    if ($null -eq $Object) { return }
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name=$Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# Capture the fully hardened report renderer after all earlier report wrappers load.
$script:SitecReportBeforeRamPresentationPolicy=${function:New-SitecCustomerReport}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    # Deep-clone the report input so presentation changes never alter the real
    # hardware evidence used by validation, HWID, Baseline JSON or Full JSON.
    $reportRun=($Run | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    foreach ($memory in @($reportRun.Hardware.Memory)) {
        Set-SitecPresentationProperty -Object $memory -Name 'Manufacturer' -Value 'Crucial'
        Set-SitecPresentationProperty -Object $memory -Name 'PartNumber' -Value ''
        Set-SitecPresentationProperty -Object $memory -Name 'SerialNumber' -Value ''
        Set-SitecPresentationProperty -Object $memory -Name 'ConfiguredSpeedMHz' -Value $null
        Set-SitecPresentationProperty -Object $memory -Name 'RatedSpeedMHz' -Value $null
    }

    & $script:SitecReportBeforeRamPresentationPolicy -Run $reportRun -RunPath $RunPath -Context $Context
}
