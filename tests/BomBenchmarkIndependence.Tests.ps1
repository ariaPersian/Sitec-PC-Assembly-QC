#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot

$worker=Get-Content -LiteralPath (Join-Path $root 'Invoke-SitecQC.ps1') -Raw -Encoding UTF8
if ($worker -match [regex]::Escape("Benchmark skipped because expected BOM validation failed")) {
    throw 'Selected benchmarks can still be skipped because BOM validation failed.'
}
if ($worker -match [regex]::Escape('if ($bom.Status -eq ''PASS'' -or $ContinueBenchmarkOnBomFailure)')) {
    throw 'Benchmark execution is still conditionally gated by BOM status.'
}
if ($worker -notmatch [regex]::Escape("Profile mismatch recorded as advisory; running selected hardware QC normally")) {
    throw 'Independent optional-profile/benchmark execution status is not present.'
}
if ($worker -notmatch [regex]::Escape("Identity/integrity validation failed; running selected benchmarks independently")) {
    throw 'Independent blocking identity/benchmark execution status is not present.'
}

$start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
if ($start -notmatch [regex]::Escape("'-ContinueBenchmarkOnBomFailure'")) {
    throw 'GUI compatibility safeguard for continue-on-BOM-failure is missing.'
}
if ($start -notmatch [regex]::Escape("'-BenchmarkComponents',(Q `$benchmarkCsv)")) {
    throw 'Operator benchmark selection forwarding was lost.'
}

$profile=Get-Content -LiteralPath (Join-Path $root 'profiles\B760-13700K-64GB-990PRO.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$profile.Expected.CpuModelContains -ne 'i7-13700K' -or [double]$profile.Expected.MemoryTotalGB -ne 64) {
    throw 'Current production profile does not match the 13700K / 64 GB reference PC.'
}

$report=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZZZ-ReportTwoPage.ps1') -Raw -Encoding UTF8
if ($report -notmatch [regex]::Escape('$allChecks=@($bomChecks)+@($benchmarkChecks)')) {
    throw 'Two-page report does not combine BOM and benchmark validation failures.'
}
if ($report -notmatch [regex]::Escape('Exact Error / Failure Reason')) {
    throw 'Two-page report does not expose the exact failure reason.'
}

$full=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZZZZZZZZZZZZZ-PresentationAndFullOutput.ps1') -Raw -Encoding UTF8
if ($full -notmatch [regex]::Escape('ErrorSummary')) { throw 'Full JSON ErrorSummary is missing.' }
if ($full -notmatch [regex]::Escape('ErrorDetails')) { throw 'Full JSON ErrorDetails are missing.' }

Write-Host 'BOM/benchmark independence and failure-reporting tests passed.' -ForegroundColor Green
