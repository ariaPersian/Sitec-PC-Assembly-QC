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
$profile=Get-SitecProfile -Context $context -ProfileId $ProfileId
if ([string]::IsNullOrWhiteSpace($CaseModel)) { $CaseModel=[string]$profile.Expected.CaseModel }
if ([string]::IsNullOrWhiteSpace($PsuModel)) { $PsuModel=[string]$profile.Expected.PsuModel }

$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Sitec QC must run as Administrator.' }

$data=[string]$context.Settings.DataRoot
New-Item -ItemType Directory -Path $data -Force | Out-Null
$runId='{0}-{1}' -f $AssetId,(Get-Date -Format 'yyyyMMdd-HHmmss')
$assetRoot=Join-Path $data ("Assets\$AssetId")
$runPath=Join-Path $assetRoot ("Runs\$runId")
@('benchmark','photos','passmark') | ForEach-Object { New-Item -ItemType Directory -Path (Join-Path $runPath $_) -Force | Out-Null }
$statusPath=Join-Path $runPath 'status.json'
$logPath=Join-Path $runPath 'worker.log'

function Set-WorkerStatus([string]$Stage,[int]$Percent,[string]$Message,[string]$State='RUNNING') {
    $o=[ordered]@{ RunId=$runId; AssetId=$AssetId; Stage=$Stage; Percent=$Percent; Message=$Message; State=$State; UpdatedAt=(Get-Date).ToString('o'); RunPath=$runPath }
    $tmp=$statusPath+'.tmp'
    $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $statusPath -Force
    "[$(Get-Date -Format HH:mm:ss)] [$Stage] $Message" | Tee-Object -FilePath $logPath -Append | Write-Host
}

try {
    Set-WorkerStatus 'Inventory' 5 'Collecting hardware inventory'
    $hardware=Get-SitecHardwareInventory
    $physical=[pscustomobject]@{ CaseModel=$CaseModel; PsuModel=$PsuModel; PsuSerial=$PsuSerial.Trim(); CpuAtpo=$CpuAtpo.Trim(); Cooler=$Cooler.Trim(); Seal1=$Seal1.Trim(); Seal2=$Seal2.Trim() }

    Set-WorkerStatus 'Validation' 18 'Validating expected BOM and serial identity'
    $bom=Test-SitecExpectedBom -Hardware $hardware -Physical $physical -Profile $profile
    $duplicates=@(Find-SitecDuplicateSerials -DataRoot $data -AssetId $AssetId -Hardware $hardware -Physical $physical)
    if ($duplicates.Count -gt 0) {
        $dupChecks=@($duplicates | ForEach-Object { New-SitecCheck -Name ("Duplicate {0} serial" -f $_.Type) -Expected 'Unique in fleet' -Actual ("{0} already registered to {1}" -f $_.Serial,$_.ExistingAssetId) -Passed $false })
        $bom.Checks=@($bom.Checks)+$dupChecks
        $bom.Status='FAIL'
    }

    $runStart=Get-Date
    $passmark=@(Import-SitecPassMarkEvidence -Context $context -RunPath $runPath -Since $runStart -AssetId $AssetId)
    if ($bom.Status -eq 'PASS' -or $ContinueBenchmarkOnBomFailure) {
        Set-WorkerStatus 'Benchmark' 28 'Running CPU, memory, sensor, storage and WHEA QC workloads'
        $benchmark=Invoke-SitecBenchmarkSuite -Context $context -RunPath $runPath
        $benchValidation=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
    } else {
        Set-WorkerStatus 'Benchmark' 55 'Benchmark skipped because expected BOM validation failed'
        $benchmark=[pscustomobject]@{
            StartedAt=$null; FinishedAt=$null;
            WinSAT=[pscustomobject]@{Available=$false;Status='SKIPPED';CpuCompressionMBps=$null;MemoryMBps=$null};
            Stress=[pscustomobject]@{Status='SKIPPED';CpuStress=[pscustomobject]@{Seconds=0;Threads=0;HashWorkMBps=0;Iterations=0};MemoryVerification=[pscustomobject]@{RequestedMB=0;VerifiedMB=0;Errors=0;Seconds=0};Sensors=@()};
            DiskSpd=[pscustomobject]@{Available=$false;Required=$false;Status='SKIPPED';SequentialReadMBps=$null;SequentialWriteMBps=$null;RandomReadIOPS=$null};
            WHEA=[pscustomobject]@{Count=0;Events=@()}
        }
        $benchValidation=[pscustomobject]@{Status='SKIPPED';Checks=@(New-SitecCheck -Name 'Benchmark suite' -Expected 'BOM PASS before benchmark' -Actual 'Skipped because BOM failed' -Passed $false -Severity 'Warning')}
    }

    $overall=if ($bom.Status -eq 'PASS' -and ($benchValidation.Status -eq 'PASS' -or $benchValidation.Status -eq 'SKIPPED')) {'PASS'} else {'FAIL'}
    $run=[pscustomobject]@{
        SchemaVersion='1.0'
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
        Security=$null
    }

    Set-WorkerStatus 'Evidence' 82 'Writing immutable-style manifest and generating evidence protection'
    $manifest=Join-Path $runPath 'hardware-qc-manifest.json'
    $run | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $security=Protect-SitecManifest -ManifestPath $manifest -Context $context
    $run.Security=$security

    Set-WorkerStatus 'Report' 90 'Generating customer HTML/PDF certificate'
    $report=New-SitecCustomerReport -Run $run -RunPath $runPath -Context $context
    Write-SitecEvidenceHashes -RunPath $runPath | Out-Null

    if ($overall -eq 'PASS') {
        $baselineRoot=Join-Path $assetRoot 'Baseline'
        $baselineManifest=Join-Path $baselineRoot 'hardware-qc-manifest.json'
        if (-not (Test-Path -LiteralPath $baselineManifest)) {
            New-Item -ItemType Directory -Path $baselineRoot -Force | Out-Null
            Copy-Item -LiteralPath $manifest -Destination $baselineManifest
            Copy-Item -LiteralPath ([IO.Path]::ChangeExtension($manifest,'.sha256')) -Destination (Join-Path $baselineRoot 'hardware-qc-manifest.sha256') -ErrorAction SilentlyContinue
            if ($security.Signed) {
                Copy-Item -LiteralPath $security.SignaturePath -Destination (Join-Path $baselineRoot 'hardware-qc-manifest.json.sig')
                Copy-Item -LiteralPath $security.CertificatePath -Destination (Join-Path $baselineRoot 'hardware-qc-manifest.json.cer')
            }
        }
    }

    Update-SitecFleetIndex -DataRoot $data -Run $run
    Set-WorkerStatus 'Complete' 100 "QC complete: $overall" 'COMPLETE'
    [pscustomobject]@{ AssetId=$AssetId; RunId=$runId; OverallStatus=$overall; RunPath=$runPath; Manifest=$manifest; Html=$report.HtmlPath; Pdf=$report.PdfPath } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runPath 'result.json') -Encoding UTF8
    if ($overall -eq 'PASS') { exit 0 } else { exit 2 }
} catch {
    $msg=$_.Exception.Message
    try { Set-WorkerStatus 'Error' 100 $msg 'ERROR' } catch {}
    $msg | Set-Content -LiteralPath (Join-Path $runPath 'fatal-error.txt') -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Error $_
    exit 1
}
