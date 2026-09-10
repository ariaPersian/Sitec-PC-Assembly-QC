function ConvertTo-SitecHtml {
    param($Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-SitecStatusClass {
    param([string]$Status)
    switch ($Status) {
        'PASS' {'pass'}
        'WARNING' {'warn'}
        'SKIPPED' {'muted'}
        default {'fail'}
    }
}

function Get-SitecMaxTemperature {
    param($Sensors,[string]$HardwareTypeContains)
    $temps=@($Sensors | Where-Object { $_.SensorType -eq 'Temperature' -and $_.Hardware -like "*$HardwareTypeContains*" } | Select-Object -ExpandProperty Max)
    if ($temps.Count -eq 0) { return $null }
    [math]::Round(($temps | Measure-Object -Maximum).Maximum,1)
}

function Import-SitecPassMarkEvidence {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)][datetime]$Since,[Parameter(Mandatory)][string]$AssetId)
    $dest=Join-Path $RunPath 'passmark'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if (-not $Context.Settings.PassMark -or -not $Context.Settings.PassMark.Enabled) { return @() }
    $source=[string]$Context.Settings.PassMark.ReportDirectory
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source)) { return @() }
    $minDate=$Since.AddMinutes(-[int]$Context.Settings.PassMark.MaxReportAgeMinutes)
    $files=@(Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -ge $minDate -and $_.Extension -in '.html','.htm','.pdf','.txt','.log' -and $_.BaseName -like "*$AssetId*"
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force }
    @($files | Select-Object Name,LastWriteTime,Length)
}

function Convert-SitecHtmlToPdf {
    param([Parameter(Mandatory)][string]$HtmlPath,[Parameter(Mandatory)][string]$PdfPath)
    $edgeCandidates=@(
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $edge=$edgeCandidates | Select-Object -First 1
    if (-not $edge) { return $false }
    $uri=(New-Object System.Uri($HtmlPath)).AbsoluteUri
    $args="--headless --disable-gpu --no-pdf-header-footer --print-to-pdf=`"$PdfPath`" `"$uri`""
    $p=Start-Process -FilePath $edge -ArgumentList $args -WindowStyle Hidden -PassThru
    $null=$p.WaitForExit(60000)
    (Test-Path -LiteralPath $PdfPath)
}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    $reportPath=Join-Path $RunPath 'QC-Certificate.html'
    $pdfPath=Join-Path $RunPath 'QC-Certificate.pdf'
    $statusClass=Get-SitecStatusClass $Run.OverallStatus
    $h=$Run.Hardware; $p=$Run.Physical; $b=$Run.Benchmark
    $ramRows=@($h.Memory | ForEach-Object {
        "<tr><td>$(ConvertTo-SitecHtml $_.Slot)</td><td>$(ConvertTo-SitecHtml $_.Manufacturer)</td><td>$(ConvertTo-SitecHtml $_.PartNumber)</td><td>$(ConvertTo-SitecHtml $_.SerialNumber)</td><td>$($_.CapacityGB) GB</td><td>$($_.ConfiguredSpeedMHz) MHz</td></tr>"
    }) -join "`n"
    $diskRows=@($h.Storage | ForEach-Object {
        "<tr><td>$(ConvertTo-SitecHtml $_.Model)</td><td>$(ConvertTo-SitecHtml $_.SerialNumber)</td><td>$($_.SizeGB) GB</td><td>$(ConvertTo-SitecHtml $_.FirmwareVersion)</td><td>$(ConvertTo-SitecHtml $_.BusType)</td></tr>"
    }) -join "`n"
    $bomRows=@($Run.BomValidation.Checks | ForEach-Object {
        $c=Get-SitecStatusClass $_.Status
        "<tr><td>$(ConvertTo-SitecHtml $_.Name)</td><td>$(ConvertTo-SitecHtml $_.Expected)</td><td>$(ConvertTo-SitecHtml $_.Actual)</td><td><span class='badge $c'>$($_.Status)</span></td></tr>"
    }) -join "`n"
    $benchRows=@($Run.BenchmarkValidation.Checks | ForEach-Object {
        $c=Get-SitecStatusClass $_.Status
        "<tr><td>$(ConvertTo-SitecHtml $_.Name)</td><td>$(ConvertTo-SitecHtml $_.Expected)</td><td>$(ConvertTo-SitecHtml $_.Actual)</td><td><span class='badge $c'>$($_.Status)</span></td></tr>"
    }) -join "`n"
    $warnings=@($Run.BomValidation.Checks + $Run.BenchmarkValidation.Checks | Where-Object { $_.Status -ne 'PASS' })
    $warningHtml=''
    if ($warnings.Count -gt 0) {
        $items=@($warnings | ForEach-Object { "<li><b>$(ConvertTo-SitecHtml $_.Name)</b>: $(ConvertTo-SitecHtml $_.Actual) <span class='badge $(Get-SitecStatusClass $_.Status)'>$($_.Status)</span></li>" }) -join ''
        $warningHtml="<section><h2>Exceptions / Warnings</h2><ul>$items</ul></section>"
    }
    $pnpHtml=''
    if (@($h.PnPErrors).Count -gt 0) {
        $items=@($h.PnPErrors | ForEach-Object { "<li>$(ConvertTo-SitecHtml $_.Name) — Error $($_.ConfigManagerErrorCode)</li>" }) -join ''
        $pnpHtml="<section><h2>Device Errors</h2><ul>$items</ul></section>"
    }
    $wheaHtml=''
    if ($b.WHEA.Count -gt 0) {
        $items=@($b.WHEA.Events | ForEach-Object { "<li>$($_.TimeCreated) — Event $($_.Id): $(ConvertTo-SitecHtml $_.Message)</li>" }) -join ''
        $wheaHtml="<section><h2>WHEA Hardware Errors</h2><ul>$items</ul></section>"
    }
    $sensorRows=@($b.Stress.Sensors | Where-Object { $_.SensorType -in 'Temperature','Fan','Voltage','Clock' } | Select-Object -First 30 | ForEach-Object {
        "<tr><td>$(ConvertTo-SitecHtml $_.Hardware)</td><td>$(ConvertTo-SitecHtml $_.Sensor)</td><td>$(ConvertTo-SitecHtml $_.SensorType)</td><td>$($_.Min)</td><td>$($_.Average)</td><td>$($_.Max)</td></tr>"
    }) -join "`n"
    $sensorHtml=''
    if ($sensorRows) { $sensorHtml="<section><h2>Sensor Summary</h2><table><thead><tr><th>Hardware</th><th>Sensor</th><th>Type</th><th>Min</th><th>Avg</th><th>Max</th></tr></thead><tbody>$sensorRows</tbody></table></section>" }
    $passmarkHtml=''
    if (@($Run.PassMarkEvidence).Count -gt 0) {
        $items=@($Run.PassMarkEvidence | ForEach-Object { "<li>$(ConvertTo-SitecHtml $_.Name) — $($_.LastWriteTime)</li>" }) -join ''
        $passmarkHtml="<section><h2>PassMark Supporting Evidence</h2><ul>$items</ul></section>"
    }

    $cpuTemp=Get-SitecMaxTemperature -Sensors $b.Stress.Sensors -HardwareTypeContains 'CPU'
    $securityText=if ($Run.Security.Signed) { "RSA/SHA-256 signed — certificate $($Run.Security.Thumbprint)" } else { 'SHA-256 evidence hash (unsigned)' }
    $diskStatus=if ($b.DiskSpd.Available) { $b.DiskSpd.Status } else { 'SKIPPED' }
    $winStatus=if ($b.WinSAT.Available) { $b.WinSAT.Status } else { 'SKIPPED' }

    $html=@"
<!doctype html><html><head><meta charset='utf-8'><title>$(ConvertTo-SitecHtml $Run.AssetId) QC Certificate</title>
<style>
@page{size:A4;margin:10mm}*{box-sizing:border-box}body{font-family:Segoe UI,Arial,sans-serif;color:#18212b;background:#eef2f5;margin:0}.page{max-width:1100px;margin:20px auto;background:#fff;padding:26px;box-shadow:0 2px 14px #0002}.head{display:flex;justify-content:space-between;align-items:center;border-bottom:3px solid #263746;padding-bottom:15px}.brand{font-size:28px;font-weight:800}.subtitle{color:#667}.overall{font-size:28px;font-weight:800;padding:10px 18px;border-radius:10px}.overall.pass{background:#e7f7ed;color:#147a39}.overall.fail{background:#fdeaea;color:#b42318}.overall.warn{background:#fff4d8;color:#946200}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:18px 0}.card{border:1px solid #dde4ea;border-radius:8px;padding:12px}.label{font-size:12px;color:#667;text-transform:uppercase}.value{font-size:16px;font-weight:650;margin-top:4px}section{margin:18px 0}h2{font-size:18px;border-bottom:1px solid #e4e8ec;padding-bottom:6px}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:7px 8px;border-bottom:1px solid #e9edf0;text-align:left;vertical-align:top}th{background:#f7f9fa}.badge{display:inline-block;padding:3px 8px;border-radius:999px;font-size:11px;font-weight:750}.badge.pass{background:#e7f7ed;color:#147a39}.badge.fail{background:#fdeaea;color:#b42318}.badge.warn{background:#fff4d8;color:#946200}.badge.muted{background:#eef1f4;color:#667}.footer{margin-top:25px;border-top:1px solid #ddd;padding-top:10px;font-size:11px;color:#667;word-break:break-all}@media print{body{background:#fff}.page{margin:0;box-shadow:none;padding:0}.no-print{display:none}.cards{grid-template-columns:repeat(4,1fr)}section{break-inside:avoid}}
</style></head><body><div class='page'>
<div class='head'><div><div class='brand'>$(ConvertTo-SitecHtml $Context.Settings.Reporting.CompanyName)</div><div class='subtitle'>$(ConvertTo-SitecHtml $Context.Settings.Reporting.CertificateTitle)</div></div><div class='overall $statusClass'>$($Run.OverallStatus)</div></div>
<div class='cards'>
<div class='card'><div class='label'>Asset ID</div><div class='value'>$(ConvertTo-SitecHtml $Run.AssetId)</div></div>
<div class='card'><div class='label'>Profile</div><div class='value'>$(ConvertTo-SitecHtml $Run.Profile.ProfileId) v$($Run.Profile.ProfileVersion)</div></div>
<div class='card'><div class='label'>Operator</div><div class='value'>$(ConvertTo-SitecHtml $Run.Operator)</div></div>
<div class='card'><div class='label'>Completed</div><div class='value'>$(ConvertTo-SitecHtml $Run.CompletedAt)</div></div>
</div>
<section><h2>Assembly Identity</h2><table><tbody>
<tr><th>Case</th><td>$(ConvertTo-SitecHtml $p.CaseModel)</td><th>PSU</th><td>$(ConvertTo-SitecHtml $p.PsuModel)</td></tr>
<tr><th>PSU Serial</th><td>$(ConvertTo-SitecHtml $p.PsuSerial)</td><th>CPU Cooler</th><td>$(ConvertTo-SitecHtml $p.Cooler)</td></tr>
<tr><th>CPU ATPO</th><td>$(ConvertTo-SitecHtml $p.CpuAtpo)</td><th>Seals</th><td>$(ConvertTo-SitecHtml ($p.Seal1 + ' / ' + $p.Seal2))</td></tr>
</tbody></table></section>
<section><h2>Detected Hardware</h2><table><tbody>
<tr><th>Motherboard</th><td>$(ConvertTo-SitecHtml ($h.Motherboard.Manufacturer + ' ' + $h.Motherboard.Model))</td><th>Serial</th><td>$(ConvertTo-SitecHtml $h.Motherboard.SerialNumber)</td></tr>
<tr><th>CPU</th><td>$(ConvertTo-SitecHtml $h.CPU.Model)</td><th>Cores / Threads</th><td>$($h.CPU.Cores) / $($h.CPU.LogicalProcessors)</td></tr>
<tr><th>BIOS</th><td>$(ConvertTo-SitecHtml $h.BIOS.Version)</td><th>BIOS Date</th><td>$(ConvertTo-SitecHtml $h.BIOS.ReleaseDate)</td></tr>
<tr><th>Windows</th><td>$(ConvertTo-SitecHtml $h.Windows.Caption)</td><th>Build</th><td>$(ConvertTo-SitecHtml $h.Windows.Build)</td></tr>
</tbody></table></section>
<section><h2>Memory Modules</h2><table><thead><tr><th>Slot</th><th>Manufacturer</th><th>Part Number</th><th>Serial</th><th>Capacity</th><th>Configured Speed</th></tr></thead><tbody>$ramRows</tbody></table></section>
<section><h2>Storage</h2><table><thead><tr><th>Model</th><th>Serial</th><th>Capacity</th><th>Firmware</th><th>Bus</th></tr></thead><tbody>$diskRows</tbody></table></section>
<section><h2>Benchmark Summary</h2><table><tbody>
<tr><th>WinSAT</th><td><span class='badge $(Get-SitecStatusClass $winStatus)'>$winStatus</span></td><th>CPU Compression</th><td>$(if($null -ne $b.WinSAT.CpuCompressionMBps){"$($b.WinSAT.CpuCompressionMBps) MB/s"}else{'N/A'})</td></tr>
<tr><th>Memory Bandwidth</th><td>$(if($null -ne $b.WinSAT.MemoryMBps){"$($b.WinSAT.MemoryMBps) MB/s"}else{'N/A'})</td><th>Memory Verification</th><td>$($b.Stress.MemoryVerification.VerifiedMB) MB / $($b.Stress.MemoryVerification.Errors) errors</td></tr>
<tr><th>CPU Stress</th><td>$($b.Stress.CpuStress.Seconds)s / $($b.Stress.CpuStress.HashWorkMBps) work-MB/s</td><th>CPU Max Temp</th><td>$(if($null -ne $cpuTemp){"$cpuTemp C"}else{'N/A'})</td></tr>
<tr><th>DiskSpd</th><td><span class='badge $(Get-SitecStatusClass $diskStatus)'>$diskStatus</span></td><th>Seq Read / Write</th><td>$(if($b.DiskSpd.Available){"$($b.DiskSpd.SequentialReadMBps) / $($b.DiskSpd.SequentialWriteMBps) MB/s"}else{'N/A'})</td></tr>
<tr><th>4K Random Read</th><td>$(if($b.DiskSpd.Available){"$($b.DiskSpd.RandomReadIOPS) IOPS"}else{'N/A'})</td><th>WHEA Errors</th><td>$($b.WHEA.Count)</td></tr>
</tbody></table></section>
<section><h2>BOM Validation</h2><table><thead><tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>$bomRows</tbody></table></section>
<section><h2>QC Validation</h2><table><thead><tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>$benchRows</tbody></table></section>
$warningHtml$pnpHtml$wheaHtml$sensorHtml$passmarkHtml
<div class='footer'>Run ID: $(ConvertTo-SitecHtml $Run.RunId)<br>Manifest SHA-256: $(ConvertTo-SitecHtml $Run.Security.Sha256)<br>Evidence protection: $(ConvertTo-SitecHtml $securityText)</div>
</div></body></html>
"@
    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8
    $pdf=$false
    if ($Context.Settings.Reporting.GeneratePdf) { $pdf=Convert-SitecHtmlToPdf -HtmlPath $reportPath -PdfPath $pdfPath }
    [pscustomobject]@{ HtmlPath=$reportPath; PdfPath=if($pdf){$pdfPath}else{$null} }
}
