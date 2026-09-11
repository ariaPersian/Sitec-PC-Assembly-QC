# Append verified digital-signature metadata to the existing strict two-page report.
$script:SitecCustomerReportBeforeSignatureDetails = ${function:New-SitecCustomerReport}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    $report=& $script:SitecCustomerReportBeforeSignatureDetails -Run $Run -RunPath $RunPath -Context $Context
    if ($Run.Security -and $Run.Security.Signed -and (Test-Path -LiteralPath $report.HtmlPath)) {
        try {
            $mode=[string]$Run.Security.SignatureMode
            $thumb=[string]$Run.Security.Thumbprint
            $shortThumb=if($thumb.Length -gt 20){$thumb.Substring(0,20)+'...'}else{$thumb}
            $verified=([bool]$Run.Security.ManifestSignatureVerified -and [bool]$Run.Security.HardwareIdentitySignatureVerified)
            $detail='RSA/SHA-256 signed; verification='+$(if($verified){'PASS'}else{'FAIL'})+'; mode='+$mode+'; cert='+$shortThumb
            $html=Get-Content -LiteralPath $report.HtmlPath -Raw -Encoding UTF8
            $html=$html.Replace('RSA/SHA-256 signed',(ConvertTo-SitecHtml $detail))
            Set-Content -LiteralPath $report.HtmlPath -Value $html -Encoding UTF8
            if ($Context.Settings.Reporting.GeneratePdf) {
                Remove-Item -LiteralPath $report.PdfPath -Force -ErrorAction SilentlyContinue
                [void](Convert-SitecHtmlToPdf -HtmlPath $report.HtmlPath -PdfPath $report.PdfPath)
            }
        } catch {}
    }
    $report
}
