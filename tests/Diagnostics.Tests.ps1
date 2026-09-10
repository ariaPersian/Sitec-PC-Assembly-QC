#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-Diagnostics-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $diag=Initialize-SitecDiagnostics -RunPath $temp
    Write-SitecDiagnosticEvent -RunPath $temp -Stage 'Test' -Step 'Event' -Status 'PASS' -Message 'Structured diagnostic smoke test.' -Data ([pscustomobject]@{Value=42})
    Write-SitecStepResult -RunPath $temp -Step '01-test-step' -Value ([pscustomobject]@{Status='PASS';Metric=123}) | Out-Null

    if (-not (Test-Path -LiteralPath $diag.Events)) { throw 'events.jsonl was not created.' }
    if (-not (Test-Path -LiteralPath $diag.Human)) { throw 'process.log was not created.' }
    if (-not (Test-Path -LiteralPath (Join-Path $diag.Steps '01-test-step.json'))) { throw 'step result JSON was not created.' }

    $eventLine=Get-Content -LiteralPath $diag.Events -Encoding UTF8 | Select-Object -Last 1
    $event=$eventLine | ConvertFrom-Json
    if ($event.Stage -ne 'Test' -or $event.Step -ne 'Event' -or $event.Data.Value -ne 42) { throw 'Structured diagnostic event content is invalid.' }

    if (Test-SitecCpuAtpo -Value '123') { throw 'Placeholder CPU ATPO 123 must be rejected.' }
    if (Test-SitecCpuAtpo -Value 'TEST') { throw 'Placeholder CPU ATPO TEST must be rejected.' }
    if (-not (Test-SitecCpuAtpo -Value 'A1B2C3D4E5')) { throw 'A plausible full ATPO should be accepted.' }

    $xml=Join-Path $temp 'diskspd-production.xml'
    @'
<Results>
  <TimeSpan>
    <TestTimeSeconds>900.00</TestTimeSeconds>
    <Thread><Target><ReadBytes>2684354560000</ReadBytes><ReadCount>40960000</ReadCount><WriteBytes>0</WriteBytes><WriteCount>0</WriteCount><AverageReadLatencyMilliseconds>0.700</AverageReadLatencyMilliseconds></Target></Thread>
    <Thread><Target><ReadBytes>2684354560000</ReadBytes><ReadCount>40960000</ReadCount><WriteBytes>0</WriteBytes><WriteCount>0</WriteCount><AverageReadLatencyMilliseconds>0.700</AverageReadLatencyMilliseconds></Target></Thread>
  </TimeSpan>
</Results>
'@ | Set-Content -LiteralPath $xml -Encoding UTF8
    $m=Get-SitecDiskSpdMetrics -XmlPath $xml
    if ($m.ReadMBps -lt 5600 -or $m.ReadMBps -gt 5800) { throw "Unexpected sustained DiskSpd parse result: $($m.ReadMBps) MB/s" }
    if ($m.ReadIOPS -le 0) { throw 'DiskSpd IOPS parser returned no work.' }

    $summary=Write-SitecFailureSummary -RunPath $temp `
        -BomValidation ([pscustomobject]@{Checks=@()}) `
        -BenchmarkValidation ([pscustomobject]@{Checks=@([pscustomobject]@{Name='CPU average load';Status='FAIL';Severity='Error';Expected='>= 80%';Actual='73.9%'})})
    if ($summary.FailureCount -ne 1) { throw 'Failure summary did not count the failing check.' }
    if (-not (Test-Path -LiteralPath (Join-Path $temp 'failure-summary.json'))) { throw 'failure-summary.json was not written.' }

    Write-Host 'Diagnostics and identity tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
