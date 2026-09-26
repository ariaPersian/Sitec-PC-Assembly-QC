#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot

$compact=Get-Content -LiteralPath (Join-Path $root 'Invoke-SitecQC-Compact.ps1') -Raw -Encoding UTF8
if ($compact -notmatch [regex]::Escape('$script:exitCode -notin @(0,2)')) {
    throw 'Compact worker does not distinguish completed QC FAIL from runtime errors.'
}
if ($compact -notmatch [regex]::Escape('if($script:exitCode -eq 2){exit 2}')) {
    throw 'Compact worker does not preserve exit code 2 for a completed QC FAIL.'
}
if ($compact -notmatch [regex]::Escape("QC worker runtime error; exit code")) {
    throw 'Runtime error diagnostics are not explicitly classified.'
}
if ($compact -match [regex]::Escape('if($script:exitCode -ne 0){$phase=''saving failure evidence''')) {
    throw 'Legacy behavior still creates LastFailure evidence for every non-zero QC result.'
}

$start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
if ($start -notmatch [regex]::Escape('elseif ($script:Worker.ExitCode -eq 2)')) {
    throw 'GUI does not have an explicit completed-QC-FAIL branch.'
}
if ($start -notmatch [regex]::Escape("'Complete - QC FAIL'")) {
    throw 'GUI does not label completed QC failures distinctly.'
}
if ($start -notmatch [regex]::Escape("'Runtime error'")) {
    throw 'GUI does not label runtime errors distinctly.'
}
if ($start -notmatch [regex]::Escape('ErrorSummary.PrimaryMessage')) {
    throw 'GUI does not surface the structured QC failure reason from Full JSON.'
}
if ($start -match 'QC failed\. PDF/Baseline/Full JSON and LastFailure diagnostics') {
    throw 'GUI still claims that ordinary QC FAIL generates LastFailure diagnostics.'
}

Write-Host 'QC FAIL vs runtime ERROR exit-semantics tests passed.' -ForegroundColor Green
