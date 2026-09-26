#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

function Assert-True([bool]$Condition,[string]$Message){ if(-not $Condition){ throw $Message } }

# UI/worker contract: explicit percent, elapsed, remaining and cancellation.
$xaml=Get-Content -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
foreach($name in @('BtnCancel','TxtProgressPercent','TxtElapsed','TxtRemaining')){
    Assert-True ($xaml -match ('x:Name="'+[regex]::Escape($name)+'"')) "Missing UI progress/cancel control: $name"
}
$start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
Assert-True ($start -match 'cancel\.request\.json') 'GUI does not create the cancellation request file.'
Assert-True ($start -match 'RemainingSeconds') 'GUI does not display remaining benchmark time.'
Assert-True ($start -match 'ElapsedSeconds') 'GUI does not display elapsed benchmark time.'
Assert-True ($start -match "effectiveStatus=''" -and $start -match 'fullIsCurrent') 'GUI does not derive the final classification from the current Full JSON.'
Assert-True ($start -match "effectiveStatus -in @\('FAIL','CANCELLED'\)") 'GUI can relabel a completed QC FAIL as a runtime error.'

$worker=Get-Content -LiteralPath (Join-Path $root 'Invoke-SitecQC.ps1') -Raw -Encoding UTF8
Assert-True ($worker -match 'OverallStatus=.ERROR.') 'Worker no longer creates a structured runtime-error run.'
Assert-True ($worker -match 'hardware-qc-manifest\.json') 'Runtime-error path does not preserve a partial manifest.'
Assert-True ($worker -match 'RuntimeFailure') 'Runtime-error path does not preserve structured exception details.'

# Regression for the v3.14.2 RAM-only crash: an unselected GPU must still
# provide every optional plan property referenced by result construction.
$bounded=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZ-ProductionBurnInBounded.ps1') -Raw -Encoding UTF8
Assert-True ($bounded -match "CoverageMode='None';WorkloadMode='None'") 'RAM-only GPU fallback is missing WorkloadMode.'
Assert-True ($bounded -match 'TargetAveragePercent=0;TargetPeakPercent=0') 'RAM-only GPU fallback is missing utilization target fields.'
Assert-True ($bounded -match 'Test-SitecCancellationRequested') 'Burn-in loop is not cancellation-aware.'
Assert-True ($bounded -match 'RemainingSeconds') 'Burn-in loop does not publish remaining time.'

$watchdog=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZ-BurnInWatchdog.ps1') -Raw -Encoding UTF8
Assert-True ($watchdog -match 'New-SitecBurnInCancelledResult') 'Watchdog has no structured CANCELLED result.'
Assert-True ($watchdog -match 'taskkill\.exe') 'Watchdog cannot stop the owned benchmark process tree.'

$previousSelection=$env:SITECQC_BENCHMARK_COMPONENTS
try {
    $env:SITECQC_BENCHMARK_COMPONENTS='Memory'
    $cancelled=New-SitecBurnInCancelledResult -DurationSeconds 480 -ActualSeconds 73.5 -Reason 'Operator test cancellation.'
    Assert-True ($cancelled.Status -eq 'CANCELLED' -and [bool]$cancelled.Cancelled) 'Cancellation result is not explicit.'
    Assert-True ($cancelled.MemoryVerification.Enabled -and $cancelled.MemoryVerification.Status -eq 'CANCELLED') 'Selected RAM is not marked CANCELLED.'
    Assert-True (-not $cancelled.GraphicsStress.Enabled -and $cancelled.GraphicsStress.WorkloadMode -eq 'None') 'Unselected GPU cancellation schema is incomplete.'
} finally {
    $env:SITECQC_BENCHMARK_COMPONENTS=$previousSelection
}

# Full JSON must retain the rich sample-compatible top-level shape and exact
# benchmark exception metadata even when the benchmark child crashes.
$temp=Join-Path $env:TEMP ('SitecQC-FullJson-Failure-Test-'+[guid]::NewGuid().ToString('N'))
$baselineRoot=Join-Path $temp 'BaselineQC'
$runPath=Join-Path $temp 'run'
New-Item -ItemType Directory -Path (Join-Path $runPath 'diagnostics'),$baselineRoot -Force | Out-Null
try {
    $manifestObject=[pscustomobject]@{
        SchemaVersion='1.2'
        AssetId='CASE-ERROR'
        RunId='CASE-ERROR-20260926-150000'
        Operator='Test'
        StartedAt='2026-09-26T15:00:00+03:30'
        CompletedAt='2026-09-26T15:08:30+03:30'
        OverallStatus='ERROR'
        Profile=[pscustomobject]@{ProfileId='B760-14700K-990PRO';ProfileVersion=8;Expected=[pscustomobject]@{StorageModelContains='990 PRO'}}
        Physical=[pscustomobject]@{CaseModel='GREEN AVA+';PsuModel='GREEN GP700A-GED V3.1';PsuSerial='PSU001';CpuAtpo='ATPO001';Cooler='DeepCool AG400 PLUS';Seal1='CASE-ERROR';Seal2=''}
        Hardware=[pscustomobject]@{
            ComputerName='TEST-PC';SystemUUID='UUID-ERROR'
            Motherboard=[pscustomobject]@{Manufacturer='ASUS';Model='TUF GAMING B760-PLUS WIFI';SerialNumber='MB001'}
            CPU=[pscustomobject]@{Model='Intel Core i7-14700K';Cores=20;LogicalProcessors=28}
            Memory=@([pscustomobject]@{Slot='A2';Manufacturer='Crucial';PartNumber='RAM001';SerialNumber='RAMSER001';CapacityGB=16;ConfiguredSpeedMHz=4800})
            Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';SerialNumber='SSD001';FirmwareVersion='FW';SizeGB=931;BusType='NVMe'})
            Graphics=@([pscustomobject]@{Name='Intel UHD Graphics'})
            BIOS=[pscustomobject]@{Version='1836';ReleaseDate='2026-04-16'}
        }
        BomValidation=[pscustomobject]@{Status='PASS';Checks=@()}
        BenchmarkSelection=@('Memory')
        Benchmark=[pscustomobject]@{
            Selection=@('Memory');StartedAt='2026-09-26T15:00:10+03:30';FinishedAt='2026-09-26T15:08:25+03:30';Cancelled=$false
            WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuStatus='SKIPPED';MemoryStatus='PASS';MemoryMBps=56543}
            DiskSpd=[pscustomobject]@{Available=$false;Required=$false;Status='SKIPPED'}
            BurnIn=[pscustomobject]@{Status='FAIL';Error="The property 'WorkloadMode' cannot be found on this object.";TimedOut=$true;DurationSeconds=480;ActualSeconds=492.3}
            Stress=[pscustomobject]@{Status='FAIL';Error="The property 'WorkloadMode' cannot be found on this object.";TimedOut=$true;DurationSeconds=480;ActualSeconds=492.3}
            WHEA=[pscustomobject]@{Count=0;Events=@()}
        }
        BenchmarkValidation=[pscustomobject]@{Status='FAIL';Checks=@([pscustomobject]@{Name='Selected hardware burn-in';Expected='PASS';Actual='FAIL';Passed=$false;Severity='Error';Status='FAIL'})}
        DuplicateSerials=@()
        PassMarkEvidence=@()
        Diagnostics=[pscustomobject]@{Events='events.jsonl';ProcessLog='process.log';FailureSummary='failure-summary.json'}
        Execution=[pscustomobject]@{Cancelled=$false;RuntimeError=$true}
        RuntimeFailure=$null
        Security=$null
    }

    $manifest=Join-Path $runPath 'hardware-qc-manifest.json'
    $manifestObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $resultPath=Join-Path $runPath 'result.json'
    [pscustomobject]@{HardwareIdentitySha256='HWID';ManifestSha256='MANIFEST'} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8

    $childError=[pscustomobject]@{
        Time='2026-09-26T15:18:25.1367871+03:30'
        Message="The property 'WorkloadMode' cannot be found on this object. Verify that the property exists."
        ExceptionType='System.Management.Automation.PropertyNotFoundException'
        FullyQualifiedErrorId='PropertyNotFoundStrict'
        ScriptStackTrace='at Invoke-SitecFullSystemBurnIn, ZZZZZZZ-ProductionBurnInBounded.ps1: line 233'
        PositionMessage='At ZZZZZZZ-BurnInWatchdog.ps1:39 char:16'
    }
    $childError | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runPath 'diagnostics\burnin-child-error.json') -Encoding UTF8

    $fullPath=Publish-SitecFullJson -BaselineRoot $baselineRoot -AssetId 'CASE-ERROR' -ManifestPath $manifest -ResultPath $resultPath
    Assert-True (Test-Path -LiteralPath $fullPath) 'Full JSON was not published for the runtime-error fixture.'
    $full=Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach($property in @('SchemaVersion','AssetId','RunId','Operator','StartedAt','CompletedAt','OverallStatus','Profile','Physical','Hardware','BomValidation','Benchmark','BenchmarkValidation','Diagnostics','Security','FullExportSchema','PublishedFiles','ExcelInventory','ErrorSummary','ErrorDetails','BenchmarkFailure')){
        Assert-True ([bool]$full.PSObject.Properties[$property]) "Full JSON is missing top-level field: $property"
    }
    Assert-True ($full.FullExportSchema -eq 'SITEC-QC-FULL-V1') 'Full JSON schema compatibility marker is incorrect.'
    Assert-True (-not $full.Diagnostics.PSObject.Properties['ProcessLog']) 'Full JSON still publishes the obsolete diagnostics/process.log path.'
    Assert-True (-not $full.Diagnostics.PSObject.Properties['FailureSummary']) 'Full JSON still publishes the obsolete failure-summary.json path.'
    Assert-True ($full.ErrorSummary.HasErrors -and $full.ErrorSummary.Count -gt 0) 'Runtime error did not populate ErrorSummary.'
    $exact=@($full.ErrorDetails | Where-Object Source -eq 'BurnInChild' | Select-Object -First 1)
    Assert-True ($exact.Count -eq 1) 'Exact burn-in child exception was not persisted.'
    Assert-True ($exact[0].ExceptionType -eq 'System.Management.Automation.PropertyNotFoundException') 'ExceptionType was not preserved.'
    Assert-True ($exact[0].FullyQualifiedErrorId -eq 'PropertyNotFoundStrict') 'FullyQualifiedErrorId was not preserved.'
    Assert-True ($exact[0].ScriptStackTrace -match 'ProductionBurnInBounded') 'PowerShell script stack was not preserved.'
    Assert-True ($full.BenchmarkFailure.HasFailure) 'BenchmarkFailure summary was not generated.'
    Assert-True ($full.BenchmarkFailure.Message -match 'WorkloadMode') 'BenchmarkFailure does not contain the exact benchmark error.'
    Assert-True ($full.ExcelInventory.'PC Tag ID' -eq 'CASE-ERROR') 'ExcelInventory projection is missing from Full JSON.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Progress, cancellation, RAM-only regression and Full JSON failure-evidence tests passed.' -ForegroundColor Green
