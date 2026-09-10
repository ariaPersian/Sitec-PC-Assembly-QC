function ConvertTo-SitecHtml {
    param($Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Test-SitecReportValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    return $true
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
    $temps=@($Sensors | Where-Object {
        $_.SensorType -eq 'Temperature' -and
        $_.Hardware -like ('*' + $HardwareTypeContains + '*') -and
        $null -ne $_.Max
    } | Select-Object -ExpandProperty Max)
    if ($temps.Count -eq 0) { return $null }
    [math]::Round(($temps | Measure-Object -Maximum).Maximum,1)
}

function New-SitecPropertySection {
    param([Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)]$Items)
    $usable=@($Items | Where-Object { Test-SitecReportValue $_.Value })
    if ($usable.Count -eq 0) { return '' }

    $rows=''
    for ($i=0;$i -lt $usable.Count;$i+=2) {
        $a=$usable[$i]
        $left='<th>{0}</th><td>{1}</td>' -f (ConvertTo-SitecHtml $a.Label),(ConvertTo-SitecHtml $a.Value)
        $right='<th></th><td></td>'
        if (($i+1) -lt $usable.Count) {
            $b=$usable[$i+1]
            $right='<th>{0}</th><td>{1}</td>' -f (ConvertTo-SitecHtml $b.Label),(ConvertTo-SitecHtml $b.Value)
        }
        $rows += '<tr>'+$left+$right+'</tr>'
    }
    '<section><h2>'+(ConvertTo-SitecHtml $Title)+'</h2><table><tbody>'+$rows+'</tbody></table></section>'
}

function New-SitecObjectTableSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)]$Columns
    )
    $rowsArray=@($Rows)
    if ($rowsArray.Count -eq 0) { return '' }

    $active=@()
    foreach ($column in $Columns) {
        $has=$false
        foreach ($row in $rowsArray) {
            $value=& $column.Getter $row
            if (Test-SitecReportValue $value) { $has=$true;break }
        }
        if ($has) { $active += $column }
    }
    if ($active.Count -eq 0) { return '' }

    $head='<tr>'+(($active | ForEach-Object { '<th>'+(ConvertTo-SitecHtml $_.Label)+'</th>' }) -join '')+'</tr>'
    $body=''
    foreach ($row in $rowsArray) {
        $cells=''
        foreach ($column in $active) {
            $value=& $column.Getter $row
            $cells += '<td>'+(ConvertTo-SitecHtml $value)+'</td>'
        }
        $body += '<tr>'+$cells+'</tr>'
    }
    '<section><h2>'+(ConvertTo-SitecHtml $Title)+'</h2><table><thead>'+$head+'</thead><tbody>'+$body+'</tbody></table></section>'
}

function Import-SitecPassMarkEvidence {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][datetime]$Since,
        [Parameter(Mandatory)][string]$AssetId
    )
    $dest=Join-Path $RunPath 'passmark'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if (-not $Context.Settings.PassMark -or -not $Context.Settings.PassMark.Enabled) { return @() }
    $source=[string]$Context.Settings.PassMark.ReportDirectory
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source)) { return @() }
    $minDate=$Since.AddMinutes(-[int]$Context.Settings.PassMark.MaxReportAgeMinutes)
    $pattern='*'+$AssetId+'*'
    $files=@(Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue | Where-Object {
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
    $edgeCandidates=@(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $edge=$edgeCandidates | Select-Object -First 1
    if (-not $edge) { return $false }
    $uri=(New-Object System.Uri($HtmlPath)).AbsoluteUri
    $arguments='--headless --disable-gpu --no-pdf-header-footer --print-to-pdf="{0}" "{1}"' -f $PdfPath,$uri
    $process=Start-Process -FilePath $edge -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $null=$process.WaitForExit(60000)
    Test-Path -LiteralPath $PdfPath
}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    $reportPath=Join-Path $RunPath 'QC-Certificate.html'
    $pdfPath=Join-Path $RunPath 'QC-Certificate.pdf'
    $h=$Run.Hardware
    $p=$Run.Physical
    $b=$Run.Benchmark

    $assemblyItems=@(
        [pscustomobject]@{Label='Case';Value=$p.CaseModel},
        [pscustomobject]@{Label='PSU';Value=$p.PsuModel},
        [pscustomobject]@{Label='PSU Serial';Value=$p.PsuSerial},
        [pscustomobject]@{Label='CPU Cooler';Value=$p.Cooler},
        [pscustomobject]@{Label='CPU ATPO';Value=$p.CpuAtpo},
        [pscustomobject]@{Label='Seal #1';Value=$p.Seal1},
        [pscustomobject]@{Label='Seal #2';Value=$p.Seal2}
    )
    $assemblySection=New-SitecPropertySection -Title 'Assembly Identity' -Items $assemblyItems

    $boardText=(@($h.Motherboard.Manufacturer,$h.Motherboard.Model) | Where-Object { Test-SitecReportValue $_ }) -join ' '
    $coresThreads=''
    if ($null -ne $h.CPU.Cores -and $null -ne $h.CPU.LogicalProcessors) { $coresThreads="$($h.CPU.Cores) / $($h.CPU.LogicalProcessors)" }
    $chassisSerial=''
    $smbiosAssetTag=''
    if ($h.PSObject.Properties['SystemEnclosure'] -and $null -ne $h.SystemEnclosure) {
        $chassisSerial=[string]$h.SystemEnclosure.SerialNumber
        $smbiosAssetTag=[string]$h.SystemEnclosure.SMBIOSAssetTag
    }

    $detectedItems=@(
        [pscustomobject]@{Label='Motherboard';Value=$boardText},
        [pscustomobject]@{Label='Motherboard Serial';Value=$h.Motherboard.SerialNumber},
        [pscustomobject]@{Label='CPU';Value=$h.CPU.Model},
        [pscustomobject]@{Label='Cores / Threads';Value=$coresThreads},
        [pscustomobject]@{Label='BIOS';Value=$h.BIOS.Version},
        [pscustomobject]@{Label='BIOS Date';Value=$h.BIOS.ReleaseDate},
        [pscustomobject]@{Label='Windows';Value=$h.Windows.Caption},
        [pscustomobject]@{Label='Windows Build';Value=$h.Windows.Build},
        [pscustomobject]@{Label='System UUID';Value=$h.SystemUUID},
        [pscustomobject]@{Label='Chassis Serial';Value=$chassisSerial},
        [pscustomobject]@{Label='SMBIOS Asset Tag';Value=$smbiosAssetTag}
    )
    $detectedSection=New-SitecPropertySection -Title 'Detected Hardware' -Items $detectedItems

    $ramColumns=@(
        [pscustomobject]@{Label='Slot';Getter={param($x)$x.Slot}},
        [pscustomobject]@{Label='Manufacturer';Getter={param($x)$x.Manufacturer}},
        [pscustomobject]@{Label='Part Number';Getter={param($x)$x.PartNumber}},
        [pscustomobject]@{Label='Serial';Getter={param($x)$x.SerialNumber}},
        [pscustomobject]@{Label='Capacity';Getter={param($x) if($null -ne $x.CapacityGB){"$($x.CapacityGB) GB"}else{''}}},
        [pscustomobject]@{Label='Type';Getter={param($x)$x.Type}},
        [pscustomobject]@{Label='Rated Speed';Getter={param($x) if($x.RatedSpeedMHz){"$($x.RatedSpeedMHz) MHz"}else{''}}},
        [pscustomobject]@{Label='Configured Speed';Getter={param($x) if($x.ConfiguredSpeedMHz){"$($x.ConfiguredSpeedMHz) MHz"}else{''}}},
        [pscustomobject]@{Label='Voltage';Getter={param($x) if($x.ConfiguredVoltage_mV){"$($x.ConfiguredVoltage_mV) mV"}else{''}}}
    )
    $ramSection=New-SitecObjectTableSection -Title 'Memory Modules' -Rows $h.Memory -Columns $ramColumns

    $diskColumns=@(
        [pscustomobject]@{Label='Model';Getter={param($x)$x.Model}},
        [pscustomobject]@{Label='Serial';Getter={param($x)$x.SerialNumber}},
        [pscustomobject]@{Label='Capacity';Getter={param($x) if($null -ne $x.SizeGB){"$($x.SizeGB) GB"}else{''}}},
        [pscustomobject]@{Label='Firmware';Getter={param($x)$x.FirmwareVersion}},
        [pscustomobject]@{Label='Media';Getter={param($x)$x.MediaType}},
        [pscustomobject]@{Label='Bus';Getter={param($x)$x.BusType}},
        [pscustomobject]@{Label='Health';Getter={param($x)$x.HealthStatus}}
    )
    $diskSection=New-SitecObjectTableSection -Title 'Storage' -Rows $h.Storage -Columns $diskColumns

    $healthRows=@()
    foreach ($disk in @($h.Storage)) {
        if ($disk.Reliability -and $disk.Reliability.Available) {
            $r=$disk.Reliability
            if ($null -ne $r.TemperatureC -or $null -ne $r.TemperatureMaxC -or $null -ne $r.PowerOnHours -or $null -ne $r.WearPercent -or $null -ne $r.ReadErrorsTotal -or $null -ne $r.WriteErrorsTotal) {
                $healthRows += [pscustomobject]@{
                    Model=$disk.Model;TemperatureC=$r.TemperatureC;TemperatureMaxC=$r.TemperatureMaxC;
                    PowerOnHours=$r.PowerOnHours;WearPercent=$r.WearPercent;ReadErrorsTotal=$r.ReadErrorsTotal;WriteErrorsTotal=$r.WriteErrorsTotal
                }
            }
        }
    }
    $healthColumns=@(
        [pscustomobject]@{Label='Model';Getter={param($x)$x.Model}},
        [pscustomobject]@{Label='Temperature';Getter={param($x) if($null -ne $x.TemperatureC){"$($x.TemperatureC) C"}else{''}}},
        [pscustomobject]@{Label='Max Temperature';Getter={param($x) if($null -ne $x.TemperatureMaxC){"$($x.TemperatureMaxC) C"}else{''}}},
        [pscustomobject]@{Label='Power-On Hours';Getter={param($x)$x.PowerOnHours}},
        [pscustomobject]@{Label='Wear';Getter={param($x) if($null -ne $x.WearPercent){"$($x.WearPercent)%"}else{''}}},
        [pscustomobject]@{Label='Read Errors';Getter={param($x)$x.ReadErrorsTotal}},
        [pscustomobject]@{Label='Write Errors';Getter={param($x)$x.WriteErrorsTotal}}
    )
    $healthSection=New-SitecObjectTableSection -Title 'Storage Reliability' -Rows $healthRows -Columns $healthColumns

    $cpuTemp=Get-SitecMaxTemperature -Sensors $b.Stress.Sensors -HardwareTypeContains 'CPU'
    $benchmarkItems=@()
    if ($b.WinSAT.Available) {
        $benchmarkItems += [pscustomobject]@{Label='WinSAT';Value=$b.WinSAT.Status}
        if ($null -ne $b.WinSAT.CpuCompressionMBps) { $benchmarkItems += [pscustomobject]@{Label='CPU Compression';Value="$($b.WinSAT.CpuCompressionMBps) MB/s"} }
        if ($null -ne $b.WinSAT.MemoryMBps) { $benchmarkItems += [pscustomobject]@{Label='Memory Bandwidth';Value="$($b.WinSAT.MemoryMBps) MB/s"} }
    }
    if ($b.Stress -and $b.Stress.Status -ne 'SKIPPED') {
        $benchmarkItems += [pscustomobject]@{Label='CPU Stress';Value="$($b.Stress.CpuStress.Seconds)s / $($b.Stress.CpuStress.HashWorkMBps) work-MB/s"}
        $benchmarkItems += [pscustomobject]@{Label='Memory Verification';Value="$($b.Stress.MemoryVerification.VerifiedMB) MB / $($b.Stress.MemoryVerification.Errors) errors"}
    }
    if ($null -ne $cpuTemp) { $benchmarkItems += [pscustomobject]@{Label='CPU Max Temperature';Value="$cpuTemp C"} }
    if ($b.DiskSpd.Available) {
        $benchmarkItems += [pscustomobject]@{Label='DiskSpd';Value=$b.DiskSpd.Status}
        if ($null -ne $b.DiskSpd.SequentialReadMBps -or $null -ne $b.DiskSpd.SequentialWriteMBps) { $benchmarkItems += [pscustomobject]@{Label='Sequential Read / Write';Value="$($b.DiskSpd.SequentialReadMBps) / $($b.DiskSpd.SequentialWriteMBps) MB/s"} }
        if ($null -ne $b.DiskSpd.RandomReadIOPS) { $benchmarkItems += [pscustomobject]@{Label='4K Random Read';Value="$($b.DiskSpd.RandomReadIOPS) IOPS"} }
    }
    if ($b.WHEA) { $benchmarkItems += [pscustomobject]@{Label='WHEA Errors';Value=[string]$b.WHEA.Count} }
    $benchmarkSection=New-SitecPropertySection -Title 'Benchmark Summary' -Items $benchmarkItems

    $bomRows=@($Run.BomValidation.Checks | ForEach-Object {
        $actual='Missing'
        if (Test-SitecReportValue $_.Actual) { $actual=[string]$_.Actual }
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class="badge {3}">{4}</span></td></tr>' -f
            (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.Expected),(ConvertTo-SitecHtml $actual),(Get-SitecStatusClass $_.Status),(ConvertTo-SitecHtml $_.Status)
    }) -join [Environment]::NewLine
    $bomSection='<section><h2>BOM Validation</h2><table><thead><tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>'+$bomRows+'</tbody></table></section>'

    $benchRows=@($Run.BenchmarkValidation.Checks | ForEach-Object {
        $actual='Missing'
        if (Test-SitecReportValue $_.Actual) { $actual=[string]$_.Actual }
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class="badge {3}">{4}</span></td></tr>' -f
            (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.Expected),(ConvertTo-SitecHtml $actual),(Get-SitecStatusClass $_.Status),(ConvertTo-SitecHtml $_.Status)
    }) -join [Environment]::NewLine
    $benchValidationSection='<section><h2>QC Validation</h2><table><thead><tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>'+$benchRows+'</tbody></table></section>'

    $exceptions=@($Run.BomValidation.Checks + $Run.BenchmarkValidation.Checks | Where-Object { $_.Status -ne 'PASS' })
    $exceptionSection=''
    if ($exceptions.Count -gt 0) {
        $items=@($exceptions | ForEach-Object {
            $actual='Missing'
            if (Test-SitecReportValue $_.Actual) { $actual=[string]$_.Actual }
            '<li><b>{0}</b>: {1} <span class="badge {2}">{3}</span></li>' -f (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $actual),(Get-SitecStatusClass $_.Status),(ConvertTo-SitecHtml $_.Status)
        }) -join ''
        $exceptionSection='<section><h2>Exceptions / Warnings</h2><ul>'+$items+'</ul></section>'
    }

    $pnpSection=''
    if (@($h.PnPErrors).Count -gt 0) {
        $items=@($h.PnPErrors | ForEach-Object { '<li>{0} — Error {1}</li>' -f (ConvertTo-SitecHtml $_.Name),$_.ConfigManagerErrorCode }) -join ''
        $pnpSection='<section><h2>Device Errors</h2><ul>'+$items+'</ul></section>'
    }

    $wheaSection=''
    if ([int]$b.WHEA.Count -gt 0) {
        $items=@($b.WHEA.Events | ForEach-Object { '<li>{0} — Event {1}: {2}</li>' -f (ConvertTo-SitecHtml $_.TimeCreated),$_.Id,(ConvertTo-SitecHtml $_.Message) }) -join ''
        $wheaSection='<section><h2>WHEA Hardware Errors</h2><ul>'+$items+'</ul></section>'
    }

    $sensorRows=@($b.Stress.Sensors | Where-Object { $_.SensorType -in 'Temperature','Fan','Voltage','Clock' -and ($null -ne $_.Min -or $null -ne $_.Average -or $null -ne $_.Max) })
    $sensorColumns=@(
        [pscustomobject]@{Label='Hardware';Getter={param($x)$x.Hardware}},
        [pscustomobject]@{Label='Sensor';Getter={param($x)$x.Sensor}},
        [pscustomobject]@{Label='Type';Getter={param($x)$x.SensorType}},
        [pscustomobject]@{Label='Min';Getter={param($x)$x.Min}},
        [pscustomobject]@{Label='Average';Getter={param($x)$x.Average}},
        [pscustomobject]@{Label='Max';Getter={param($x)$x.Max}}
    )
    $sensorSection=New-SitecObjectTableSection -Title 'Sensor Summary' -Rows ($sensorRows | Select-Object -First 30) -Columns $sensorColumns

    $passmarkSection=''
    if (@($Run.PassMarkEvidence).Count -gt 0) {
        $items=@($Run.PassMarkEvidence | ForEach-Object { '<li>{0} — {1}</li>' -f (ConvertTo-SitecHtml $_.Name),(ConvertTo-SitecHtml $_.LastWriteTime) }) -join ''
        $passmarkSection='<section><h2>PassMark Supporting Evidence</h2><ul>'+$items+'</ul></section>'
    }

    $securityText='SHA-256 evidence hash (unsigned)'
    if ($Run.Security.Signed) { $securityText='RSA/SHA-256 signed — certificate '+(ConvertTo-SitecHtml $Run.Security.Thumbprint) }
    $statusClass=Get-SitecStatusClass $Run.OverallStatus

    $html=@"
<!doctype html><html><head><meta charset="utf-8"><title>$(ConvertTo-SitecHtml $Run.AssetId) QC Certificate</title>
<style>
@page{size:A4;margin:10mm}*{box-sizing:border-box}body{font-family:Segoe UI,Arial,sans-serif;color:#18212b;background:#eef2f5;margin:0}.page{max-width:1100px;margin:20px auto;background:#fff;padding:26px;box-shadow:0 2px 14px #0002}.head{display:flex;justify-content:space-between;align-items:center;border-bottom:3px solid #263746;padding-bottom:15px}.brand{font-size:28px;font-weight:800}.subtitle{color:#667}.overall{font-size:28px;font-weight:800;padding:10px 18px;border-radius:10px}.overall.pass{background:#e7f7ed;color:#147a39}.overall.fail{background:#fdeaea;color:#b42318}.overall.warn{background:#fff4d8;color:#946200}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:18px 0}.card{border:1px solid #dde4ea;border-radius:8px;padding:12px}.label{font-size:12px;color:#667;text-transform:uppercase}.value{font-size:16px;font-weight:650;margin-top:4px}section{margin:18px 0}h2{font-size:18px;border-bottom:1px solid #e4e8ec;padding-bottom:6px}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:7px 8px;border-bottom:1px solid #e9edf0;text-align:left;vertical-align:top}th{background:#f7f9fa}.badge{display:inline-block;padding:3px 8px;border-radius:999px;font-size:11px;font-weight:750}.badge.pass{background:#e7f7ed;color:#147a39}.badge.fail{background:#fdeaea;color:#b42318}.badge.warn{background:#fff4d8;color:#946200}.badge.muted{background:#eef1f4;color:#667}.footer{margin-top:25px;border-top:1px solid #ddd;padding-top:10px;font-size:11px;color:#667;word-break:break-all}@media print{body{background:#fff}.page{margin:0;box-shadow:none;padding:0}.cards{grid-template-columns:repeat(4,1fr)}section{break-inside:avoid}}
</style></head><body><div class="page">
<div class="head"><div><div class="brand">$(ConvertTo-SitecHtml $Context.Settings.Reporting.CompanyName)</div><div class="subtitle">$(ConvertTo-SitecHtml $Context.Settings.Reporting.CertificateTitle)</div></div><div class="overall $statusClass">$(ConvertTo-SitecHtml $Run.OverallStatus)</div></div>
<div class="cards"><div class="card"><div class="label">Asset ID</div><div class="value">$(ConvertTo-SitecHtml $Run.AssetId)</div></div><div class="card"><div class="label">Profile</div><div class="value">$(ConvertTo-SitecHtml ($Run.Profile.ProfileId+' v'+$Run.Profile.ProfileVersion))</div></div><div class="card"><div class="label">Operator</div><div class="value">$(ConvertTo-SitecHtml $Run.Operator)</div></div><div class="card"><div class="label">Completed</div><div class="value">$(ConvertTo-SitecHtml $Run.CompletedAt)</div></div></div>
$assemblySection
$detectedSection
$ramSection
$diskSection
$healthSection
$benchmarkSection
$bomSection
$benchValidationSection
$exceptionSection
$pnpSection
$wheaSection
$sensorSection
$passmarkSection
<div class="footer">Run ID: $(ConvertTo-SitecHtml $Run.RunId)<br>Manifest SHA-256: $(ConvertTo-SitecHtml $Run.Security.Sha256)<br>Evidence protection: $securityText</div></div></body></html>
"@

    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8
    $pdf=$false
    if ($Context.Settings.Reporting.GeneratePdf) { $pdf=Convert-SitecHtmlToPdf -HtmlPath $reportPath -PdfPath $pdfPath }
    [pscustomobject]@{HtmlPath=$reportPath;PdfPath=$(if($pdf){$pdfPath}else{$null})}
}
