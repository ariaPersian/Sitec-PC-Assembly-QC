# Production presentation/export policy for v3.13.0.
# Raw hardware inventory remains untouched for validation, HWID and JSON evidence.
# Only customer-facing UI/PDF presentation normalizes RAM branding to Crucial.

function Get-SitecPublishedFullJsonPath {
    param([Parameter(Mandatory)][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ("{0}-Full.json" -f $AssetId)
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
            $details += [pscustomobject][ordered]@{
                Source='Validation';Stage=$group.Name;Status=[string]$check.Status;Severity=[string]$check.Severity
                Name=[string]$check.Name
                Message=('{0}: expected [{1}], actual [{2}]' -f $check.Name,$check.Expected,$check.Actual)
                Expected=[string]$check.Expected;Actual=[string]$check.Actual
            }
        }
    }

    if ($Run.PSObject.Properties['Benchmark'] -and $Run.Benchmark) {
        $runtimeCandidates=@()
        foreach ($name in @('WinSAT','DiskSpd','Stress','BurnIn')) {
            if ($Run.Benchmark.PSObject.Properties[$name] -and $Run.Benchmark.$name) {
                $runtimeCandidates += [pscustomobject]@{Name=$name;Value=$Run.Benchmark.$name}
            }
        }
        foreach ($candidate in $runtimeCandidates) {
            if (-not $candidate.Value.PSObject.Properties['Error'] -or [string]::IsNullOrWhiteSpace([string]$candidate.Value.Error)) { continue }
            $details += [pscustomobject][ordered]@{
                Source='RuntimeResult';Stage='Benchmark'
                Status=$(if($candidate.Value.PSObject.Properties['Status']){[string]$candidate.Value.Status}else{'ERROR'})
                Severity='ERROR';Name=[string]$candidate.Name;Message=[string]$candidate.Value.Error
                Expected='';Actual=''
            }
        }
    }

    $fatalPath=Join-Path $RunPath 'fatal-error.json'
    if (Test-Path -LiteralPath $fatalPath) {
        try {
            $fatal=Get-Content -LiteralPath $fatalPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $details += [pscustomobject][ordered]@{
                Source='UnhandledException';Stage='Fatal';Status='ERROR';Severity='ERROR';Name='UnhandledException'
                Message=[string]$fatal.Message;Expected='';Actual=''
            }
        } catch {}
    }
    @($details)
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
        Items=$errorDetails
    }
    if ($run.PSObject.Properties['ErrorSummary']) { $run.ErrorSummary=$errorSummary }
    else { $run | Add-Member -NotePropertyName ErrorSummary -NotePropertyValue $errorSummary }
    if ($run.PSObject.Properties['ErrorDetails']) { $run.ErrorDetails=$errorDetails }
    else { $run | Add-Member -NotePropertyName ErrorDetails -NotePropertyValue $errorDetails }

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
