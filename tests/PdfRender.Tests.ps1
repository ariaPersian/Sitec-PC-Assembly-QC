$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-Pdf-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $htmlPath=Join-Path $temp 'two-page.html'
    $pdfPath=Join-Path $temp 'two-page.pdf'
    @'
<!doctype html><html><head><meta charset="utf-8"><style>
@page{size:A4;margin:0}*{box-sizing:border-box}html,body{margin:0;padding:0}.sheet{width:210mm;height:297mm;padding:10mm;overflow:hidden;page-break-after:always;break-after:page}.sheet:last-child{page-break-after:auto;break-after:auto}
</style></head><body><div class="sheet">PAGE ONE</div><div class="sheet">PAGE TWO</div></body></html>
'@ | Set-Content -LiteralPath $htmlPath -Encoding UTF8

    $ok=Convert-SitecHtmlToPdf -HtmlPath $htmlPath -PdfPath $pdfPath
    if (-not $ok -or -not (Test-Path -LiteralPath $pdfPath)) { throw 'Headless Edge did not create the PDF.' }

    $bytes=[System.IO.File]::ReadAllBytes($pdfPath)
    $ascii=[System.Text.Encoding]::ASCII.GetString($bytes)
    $pageCount=[regex]::Matches($ascii,'/Type\s*/Page\b').Count
    if ($pageCount -ne 2) { throw "Expected exactly 2 PDF pages, got $pageCount." }

    Write-Host 'Two-page PDF render test passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
