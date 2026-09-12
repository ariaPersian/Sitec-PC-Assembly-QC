# Final customer-report cleanup for the streamlined operator workflow.
# The Windows username may still be retained internally in the manifest for audit/debugging,
# but it is intentionally omitted from the customer-facing two-page certificate.
$script:SitecCustomerReportBeforeOperatorCleanup = ${function:New-SitecCustomerReport}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    $report=& $script:SitecCustomerReportBeforeOperatorCleanup -Run $Run -RunPath $RunPath -Context $Context
    if (-not $report -or -not (Test-Path -LiteralPath $report.HtmlPath)) { return $report }

    try {
        $html=Get-Content -LiteralPath $report.HtmlPath -Raw -Encoding UTF8
        $updated=$html
        $updated=[regex]::Replace(
            $updated,
            '<div><span class="k">Operator</span><span class="v">.*?</span></div>',
            '',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
        $updated=$updated.Replace('grid-template-columns:repeat(4,1fr)','grid-template-columns:repeat(3,1fr)')

        if ($updated -ne $html) {
            Set-Content -LiteralPath $report.HtmlPath -Value $updated -Encoding UTF8
            if ($Context.Settings.Reporting.GeneratePdf -and $report.PdfPath) {
                Remove-Item -LiteralPath $report.PdfPath -Force -ErrorAction SilentlyContinue
                $pdfOk=Convert-SitecHtmlToPdf -HtmlPath $report.HtmlPath -PdfPath $report.PdfPath
                if (-not $pdfOk) { $report.PdfPath=$null }
            }
        }
    } catch {}

    $report
}
