function ConvertTo-SitecHtml {
    param($Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-SitecStatusClass {
    param([string]$Status)
    switch ($Status) {
        'PASS' { 'pass' }
        'WARNING' { 'warn' }
        'SKIPPED' { 'muted' }
        default { 'fail' }
    }
}

function Get-SitecMaxTemperature {
    param($Sensors,[string]$HardwareTypeContains)
    $temps = @($Sensors | Where-Object {
        $_.SensorType -eq 'Temperature' -and $_.Hardware -like ('*' + $HardwareTypeContains + '*')
    } | Select-Object -ExpandProperty Max)
    if ($temps.Count -eq 0) { return $null }
    [math]::Round(($temps | Measure-Object -Maximum).Maximum,1)
}

function Import-SitecPassMarkEvidence {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][datetime]$Since,
        [Parameter(Mandatory)][string]$AssetId
    )
    $dest = Join-Path $RunPath 'passmark'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if (-not $Context.Settings.PassMark -or -not $Context.Settings.PassMark.Enabled) { return @() }
    $source = [string]$Context.Settings.PassMark.ReportDirectory
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source)) { return @() }
    $minDate = $Since.AddMinutes(-[int]$Context.Settings.PassMark.MaxReportAgeMinutes)
    $pattern = '*' + $AssetId + '*'
    $files = @(Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -ge $minDate -and
        $_.Extension -in '.html','.htm','.pdf','.txt','.log' -and
        $_.BaseName -like $pattern
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    foreach ($f in $files) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force
    }
    @($files | Select-Object Name,LastWriteTime,Length)
}

function Convert-SitecHtmlToPdf {
    param([Parameter(Mandatory)][string]$HtmlPath,[Parameter(Mandatory)][string]$PdfPath)
    $edgeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $edge = $edgeCandidates | Select-Object -First 1
    if (-not $edge) { return $false }
    $uri = (New-Object System.Uri($HtmlPath)).AbsoluteUri
    $arguments = '--headless --disable-gpu --no-pdf-header-footer --print-to-pdf="{0}" "{1}"' -f $PdfPath,$uri
    $p = Start-Process -FilePath $edge -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $null = $p.WaitForExit(60000)
    Test-Path -LiteralPath $PdfPath
}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    $reportPath = Join-Path $RunPath 'QC-Certificate.html'
    $pdfPath = Join-Path $RunPath 'QC-Certificate.pdf'
    $h = $Run.Hardware
    $p = $Run.Physical
    $b = $Run.Benchmark

    $ramRows = @($h.Memory | ForEach-Object {
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4} GB</td><td>{5} MHz</td></tr>' -f
            (ConvertTo-SitecHtml $_.Slot),(ConvertTo-SitecHtml $_.Manufacturer),(ConvertTo-SitecHtml $_.PartNumber),
            (ConvertTo-SitecHtml $_.SerialNumber),$_.CapacityGB,$_.ConfiguredSpeedMHz
    }) -join [Environment]::NewLine

    $diskRows = @($h.Storage | ForEach-Object {
        '<tr><td>{0}</td><td>{1}</td><td>{2} GB</td><td>{3}</td><td>{4}</td></tr>' -f
            (ConvertTo-SitecHtml $_.Model),(ConvertTo-SitecHtml $_.SerialNumber),$_.SizeGB,
            (ConvertTo-SitecHtml $_.FirmwareVersion),(ConvertTo-SitecHtml $_.BusType)
    }) -join [Environment]::NewLine

    $bomRows = @($Run.BomValidation.Checks | ForEach-Object {
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class="badge {3}">{4}</span></td></tr>' -f
            (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.Expected),(ConvertTo-SitecHtml $_.Actual),
            (Get-SitecStatusClass $_.Status),(ConvertTo-SitecHtml $_.Status)
    }) -join [Environment]::NewLine

    $benchRows = @($Run.BenchmarkValidation.Checks | ForEach-Object {
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class="badge {3}">{4}</span></td></tr>' -f
            (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.Expected),(ConvertTo-SitecHtml $_.Actual),
            (Get-SitecStatusClass $_.Status),(ConvertTo-SitecHtml $_.Status)
    }) -join [Environment]::NewLine

    $exceptions = @($Run.BomValidation.Checks + $Run.BenchmarkValidation.Checks | Where-Object { $_.Status -ne 'PASS' })
    $exceptionSection = ''
    if ($exceptions.Count -gt 0) {
        $items = @($exceptions | ForEach-Object {
            '<li><b>{0}</b>: {1} <span class="badge {2}">{3}</span></li>' -f
                (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.Actual),(Get-SitecStatusClass $_.Status),(ConvertTo-SitecHtml $_.Status)
        }) -join ''
        $exceptionSection = '<section><h2>Exceptions / Warnings</h2><ul>' + $items + '</ul></section>'
    }

    $pnpSection = ''
    if (@($h.PnPErrors).Count -gt 0) {
        $items = @($h.PnPErrors | ForEach-Object {
            '<li>{0} — Error {1}</li>' -f (ConvertTo-SitecHtml $_.Name),$_.ConfigManagerErrorCode
        }) -join ''
        $pnpSection = '<section><h2>Device Errors</h2><ul>' + $items + '</ul></section>'
    }

    $wheaSection = ''
    if ([int]$b.WHEA.Count -gt 0) {
        $items = @($b.WHEA.Events | ForEach-Object {
            '<li>{0} — Event {1}: {2}</li>' -f (ConvertTo-SitecHtml $_.TimeCreated),$_.Id,(ConvertTo-SitecHtml $_.Message)
        }) -join ''
        $wheaSection = '<section><h2>WHEA Hardware Errors</h2><ul>' + $items + '</ul></section>'
    }

    $sensorSection = ''
    $sensorRows = @($b.Stress.Sensors | Where-Object { $_.SensorType -in 'Temperature','Fan','Voltage','Clock' } | Select-Object -First 30 | ForEach-Object {
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f
            (ConvertTo-SitecHtml $_.Hardware),(ConvertTo-SitecHtml $_.Sensor),(ConvertTo-SitecHtml $_.SensorType),$_.Min,$_.Average,$_.Max
    }) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($sensorRows)) {
        $sensorSection = '<section><h2>Sensor Summary</h2><table><thead><tr><th>Hardware</th><th>Sensor</th><th>Type</th><th>Min</th><th>Avg</th><th>Max</th></tr></thead><tbody>' + $sensorRows + '</tbody></table></section>'
    }

    $passmarkSection = ''
    if (@($Run.PassMarkEvidence).Count -gt 0) {
        $items = @($Run.PassMarkEvidence | ForEach-Object {
            '<li>{0} — {1}</li>' -f (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.LastWriteTime)
        }) -join ''
        $passmarkSection = '<section><h2>PassMark Supporting Evidence</h2><ul>' + $items + '</ul></section>'
    }

    $cpuTemp = Get-SitecMaxTemperature -Sensors $b.Stress.Sensors -HardwareTypeContains 'CPU'
    $securityText = if ($Run.Security.Signed) {
        'RSA/SHA-256 signed — certificate ' + (ConvertTo-SitecHtml $Run.Security.Thumbprint)
    } else { 'SHA-256 evidence hash (unsigned)' }
    $diskStatus = if ($b.DiskSpd.Available) { [string]$b.DiskSpd.Status } else { 'SKIPPED' }
    $winStatus = if ($b.WinSAT.Available) { [string]$b.WinSAT.Status } else { 'SKIPPED' }

    $template = @'
<!doctype html>
<html><head><meta charset="utf-8"><title>{{ASSET}} QC Certificate</title>
<style>
@page{size:A4;margin:10mm}*{box-sizing:border-box}body{font-family:Segoe UI,Arial,sans-serif;color:#18212b;background:#eef2f5;margin:0}.page{max-width:1100px;margin:20px auto;background:#fff;padding:26px;box-shadow:0 2px 14px #0002}.head{display:flex;justify-content:space-between;align-items:center;border-bottom:3px solid #263746;padding-bottom:15px}.brand{font-size:28px;font-weight:800}.subtitle{color:#667}.overall{font-size:28px;font-weight:800;padding:10px 18px;border-radius:10px}.overall.pass{background:#e7f7ed;color:#147a39}.overall.fail{background:#fdeaea;color:#b42318}.overall.warn{background:#fff4d8;color:#946200}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:18px 0}.card{border:1px solid #dde4ea;border-radius:8px;padding:12px}.label{font-size:12px;color:#667;text-transform:uppercase}.value{font-size:16px;font-weight:650;margin-top:4px}section{margin:18px 0}h2{font-size:18px;border-bottom:1px solid #e4e8ec;padding-bottom:6px}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:7px 8px;border-bottom:1px solid #e9edf0;text-align:left;vertical-align:top}th{background:#f7f9fa}.badge{display:inline-block;padding:3px 8px;border-radius:999px;font-size:11px;font-weight:750}.badge.pass{background:#e7f7ed;color:#147a39}.badge.fail{background:#fdeaea;color:#b42318}.badge.warn{background:#fff4d8;color:#946200}.badge.muted{background:#eef1f4;color:#667}.footer{margin-top:25px;border-top:1px solid #ddd;padding-top:10px;font-size:11px;color:#667;word-break:break-all}@media print{body{background:#fff}.page{margin:0;box-shadow:none;padding:0}.cards{grid-template-columns:repeat(4,1fr)}section{break-inside:avoid}}
</style></head><body><div class="page">
<div class="head"><div><div class="brand">{{COMPANY}}</div><div class="subtitle">{{TITLE}}</div></div><div class="overall {{STATUSCLASS}}">{{STATUS}}</div></div>
<div class="cards"><div class="card"><div class="label">Asset ID</div><div class="value">{{ASSET}}</div></div><div class="card"><div class="label">Profile</div><div class="value">{{PROFILE}}</div></div><div class="card"><div class="label">Operator</div><div class="value">{{OPERATOR}}</div></div><div class="card"><div class="label">Completed</div><div class="value">{{COMPLETED}}</div></div></div>
<section><h2>Assembly Identity</h2><table><tbody><tr><th>Case</th><td>{{CASE}}</td><th>PSU</th><td>{{PSU}}</td></tr><tr><th>PSU Serial</th><td>{{PSUSERIAL}}</td><th>CPU Cooler</th><td>{{COOLER}}</td></tr><tr><th>CPU ATPO</th><td>{{ATPO}}</td><th>Seals</th><td>{{SEALS}}</td></tr></tbody></table></section>
<section><h2>Detected Hardware</h2><table><tbody><tr><th>Motherboard</th><td>{{BOARD}}</td><th>Serial</th><td>{{BOARDSERIAL}}</td></tr><tr><th>CPU</th><td>{{CPU}}</td><th>Cores / Threads</th><td>{{CORES}}</td></tr><tr><th>BIOS</th><td>{{BIOS}}</td><th>BIOS Date</th><td>{{BIOSDATE}}</td></tr><tr><th>Windows</th><td>{{WINDOWS}}</td><th>Build</th><td>{{BUILD}}</td></tr></tbody></table></section>
<section><h2>Memory Modules</h2><table><thead><tr><th>Slot</th><th>Manufacturer</th><th>Part Number</th><th>Serial</th><th>Capacity</th><th>Configured Speed</th></tr></thead><tbody>{{RAMROWS}}</tbody></table></section>
<section><h2>Storage</h2><table><thead><tr><th>Model</th><th>Serial</th><th>Capacity</th><th>Firmware</th><th>Bus</th></tr></thead><tbody>{{DISKROWS}}</tbody></table></section>
<section><h2>Benchmark Summary</h2><table><tbody><tr><th>WinSAT</th><td><span class="badge {{WINCLASS}}">{{WINSTATUS}}</span></td><th>CPU Compression</th><td>{{CPUCOMP}}</td></tr><tr><th>Memory Bandwidth</th><td>{{MEMBW}}</td><th>Memory Verification</th><td>{{MEMVERIFY}}</td></tr><tr><th>CPU Stress</th><td>{{CPUSTRESS}}</td><th>CPU Max Temp</th><td>{{CPUTEMP}}</td></tr><tr><th>DiskSpd</th><td><span class="badge {{DISKCLASS}}">{{DISKSTATUS}}</span></td><th>Seq Read / Write</th><td>{{SEQ}}</td></tr><tr><th>4K Random Read</th><td>{{RANDOM}}</td><th>WHEA Errors</th><td>{{WHEA}}</td></tr></tbody></table></section>
<section><h2>BOM Validation</h2><table><thead><tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>{{BOMROWS}}</tbody></table></section>
<section><h2>QC Validation</h2><table><thead><tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>{{BENCHROWS}}</tbody></table></section>
{{EXCEPTIONS}}{{PNP}}{{WHEASECTION}}{{SENSORS}}{{PASSMARK}}
<div class="footer">Run ID: {{RUNID}}<br>Manifest SHA-256: {{SHA}}<br>Evidence protection: {{SECURITY}}</div></div></body></html>
'@

    $values = [ordered]@{
        '{{ASSET}}' = ConvertTo-SitecHtml $Run.AssetId
        '{{COMPANY}}' = ConvertTo-SitecHtml $Context.Settings.Reporting.CompanyName
        '{{TITLE}}' = ConvertTo-SitecHtml $Context.Settings.Reporting.CertificateTitle
        '{{STATUSCLASS}}' = Get-SitecStatusClass $Run.OverallStatus
        '{{STATUS}}' = ConvertTo-SitecHtml $Run.OverallStatus
        '{{PROFILE}}' = ConvertTo-SitecHtml ($Run.Profile.ProfileId + ' v' + $Run.Profile.ProfileVersion)
        '{{OPERATOR}}' = ConvertTo-SitecHtml $Run.Operator
        '{{COMPLETED}}' = ConvertTo-SitecHtml $Run.CompletedAt
        '{{CASE}}' = ConvertTo-SitecHtml $p.CaseModel
        '{{PSU}}' = ConvertTo-SitecHtml $p.PsuModel
        '{{PSUSERIAL}}' = ConvertTo-SitecHtml $p.PsuSerial
        '{{COOLER}}' = ConvertTo-SitecHtml $p.Cooler
        '{{ATPO}}' = ConvertTo-SitecHtml $p.CpuAtpo
        '{{SEALS}}' = ConvertTo-SitecHtml ($p.Seal1 + ' / ' + $p.Seal2)
        '{{BOARD}}' = ConvertTo-SitecHtml ($h.Motherboard.Manufacturer + ' ' + $h.Motherboard.Model)
        '{{BOARDSERIAL}}' = ConvertTo-SitecHtml $h.Motherboard.SerialNumber
        '{{CPU}}' = ConvertTo-SitecHtml $h.CPU.Model
        '{{CORES}}' = ConvertTo-SitecHtml ($h.CPU.Cores.ToString() + ' / ' + $h.CPU.LogicalProcessors.ToString())
        '{{BIOS}}' = ConvertTo-SitecHtml $h.BIOS.Version
        '{{BIOSDATE}}' = ConvertTo-SitecHtml $h.BIOS.ReleaseDate
        '{{WINDOWS}}' = ConvertTo-SitecHtml $h.Windows.Caption
        '{{BUILD}}' = ConvertTo-SitecHtml $h.Windows.Build
        '{{RAMROWS}}' = $ramRows
        '{{DISKROWS}}' = $diskRows
        '{{WINCLASS}}' = Get-SitecStatusClass $winStatus
        '{{WINSTATUS}}' = ConvertTo-SitecHtml $winStatus
        '{{CPUCOMP}}' = if ($null -ne $b.WinSAT.CpuCompressionMBps) { (ConvertTo-SitecHtml ($b.WinSAT.CpuCompressionMBps.ToString() + ' MB/s')) } else { 'N/A' }
        '{{MEMBW}}' = if ($null -ne $b.WinSAT.MemoryMBps) { (ConvertTo-SitecHtml ($b.WinSAT.MemoryMBps.ToString() + ' MB/s')) } else { 'N/A' }
        '{{MEMVERIFY}}' = ConvertTo-SitecHtml ($b.Stress.MemoryVerification.VerifiedMB.ToString() + ' MB / ' + $b.Stress.MemoryVerification.Errors.ToString() + ' errors')
        '{{CPUSTRESS}}' = ConvertTo-SitecHtml ($b.Stress.CpuStress.Seconds.ToString() + 's / ' + $b.Stress.CpuStress.HashWorkMBps.ToString() + ' work-MB/s')
        '{{CPUTEMP}}' = if ($null -ne $cpuTemp) { (ConvertTo-SitecHtml ($cpuTemp.ToString() + ' C')) } else { 'N/A' }
        '{{DISKCLASS}}' = Get-SitecStatusClass $diskStatus
        '{{DISKSTATUS}}' = ConvertTo-SitecHtml $diskStatus
        '{{SEQ}}' = if ($b.DiskSpd.Available) { (ConvertTo-SitecHtml ($b.DiskSpd.SequentialReadMBps.ToString() + ' / ' + $b.DiskSpd.SequentialWriteMBps.ToString() + ' MB/s')) } else { 'N/A' }
        '{{RANDOM}}' = if ($b.DiskSpd.Available) { (ConvertTo-SitecHtml ($b.DiskSpd.RandomReadIOPS.ToString() + ' IOPS')) } else { 'N/A' }
        '{{WHEA}}' = ConvertTo-SitecHtml $b.WHEA.Count
        '{{BOMROWS}}' = $bomRows
        '{{BENCHROWS}}' = $benchRows
        '{{EXCEPTIONS}}' = $exceptionSection
        '{{PNP}}' = $pnpSection
        '{{WHEASECTION}}' = $wheaSection
        '{{SENSORS}}' = $sensorSection
        '{{PASSMARK}}' = $passmarkSection
        '{{RUNID}}' = ConvertTo-SitecHtml $Run.RunId
        '{{SHA}}' = ConvertTo-SitecHtml $Run.Security.Sha256
        '{{SECURITY}}' = $securityText
    }
    $html = $template
    foreach ($key in $values.Keys) { $html = $html.Replace($key,[string]$values[$key]) }

    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8
    $pdf = $false
    if ($Context.Settings.Reporting.GeneratePdf) {
        $pdf = Convert-SitecHtmlToPdf -HtmlPath $reportPath -PdfPath $pdfPath
    }
    [pscustomobject]@{ HtmlPath=$reportPath; PdfPath=if ($pdf) { $pdfPath } else { $null } }
}
