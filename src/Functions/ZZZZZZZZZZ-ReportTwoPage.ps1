# Strict two-page customer certificate.
# Page 1: complete assembly/system identity. Page 2: benchmark/QC results and hashes.

function Test-SitecPrintableValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    $s=[string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    if ($s.Trim() -match '^(Default string|To Be Filled By O\.E\.M\.|System Serial Number|Not Specified|N/A)$') { return $false }
    $true
}

function ConvertTo-SitecCompactPairs {
    param([Parameter(Mandatory)]$Items)
    $usable=@($Items | Where-Object { Test-SitecPrintableValue $_.Value })
    if ($usable.Count -eq 0) { return '' }
    $html='<div class="pairs">'
    foreach($i in $usable) {
        $html += '<div class="pair"><span class="k">'+(ConvertTo-SitecHtml $i.Label)+'</span><span class="v">'+(ConvertTo-SitecHtml $i.Value)+'</span></div>'
    }
    $html+'</div>'
}

function ConvertTo-SitecCompactTable {
    param([Parameter(Mandatory)]$Rows,[Parameter(Mandatory)]$Columns)
    $r=@($Rows)
    if ($r.Count -eq 0) { return '' }
    $active=@()
    foreach($c in $Columns) {
        $has=$false
        foreach($x in $r) { if (Test-SitecPrintableValue (& $c.Getter $x)) { $has=$true;break } }
        if ($has) { $active += $c }
    }
    if ($active.Count -eq 0) { return '' }
    $h='<table><thead><tr>'+(($active|ForEach-Object{'<th>'+(ConvertTo-SitecHtml $_.Label)+'</th>'})-join '')+'</tr></thead><tbody>'
    foreach($x in $r) {
        $h+='<tr>'
        foreach($c in $active) { $h+='<td>'+(ConvertTo-SitecHtml (& $c.Getter $x))+'</td>' }
        $h+='</tr>'
    }
    $h+'</tbody></table>'
}

function Convert-SitecHtmlToPdf {
    param([Parameter(Mandatory)][string]$HtmlPath,[Parameter(Mandatory)][string]$PdfPath)
    $edgeCandidates=@(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $edge=$edgeCandidates | Select-Object -First 1
    if (-not $edge) { return $false }

    $profile=Join-Path $env:TEMP ('SitecQC-Edge-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    try {
        Remove-Item -LiteralPath $PdfPath -Force -ErrorAction SilentlyContinue
        $uri=(New-Object System.Uri($HtmlPath)).AbsoluteUri
        $args='--headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf-no-header --user-data-dir="{0}" --print-to-pdf="{1}" "{2}"' -f $profile,$PdfPath,$uri
        $p=Start-Process -FilePath $edge -ArgumentList $args -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit(60000)) {
            try { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null } catch {}
            return $false
        }
        return (Test-Path -LiteralPath $PdfPath)
    }
    finally {
        Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-SitecCustomerReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)]$Context)

    $reportPath=Join-Path $RunPath 'QC-Certificate.html'
    $pdfPath=Join-Path $RunPath 'QC-Certificate.pdf'
    $h=$Run.Hardware;$p=$Run.Physical;$b=$Run.Benchmark
    $stress=$b.Stress
    if ($null -eq $stress -and $b.PSObject.Properties['BurnIn']) { $stress=$b.BurnIn }
    $statusClass=Get-SitecStatusClass $Run.OverallStatus

    $completed=''
    try { $completed=([datetimeoffset]$Run.CompletedAt).ToString('yyyy-MM-dd HH:mm:ss zzz') } catch { $completed=[string]$Run.CompletedAt }

    $assembly=ConvertTo-SitecCompactPairs @(
        [pscustomobject]@{Label='Case';Value=$p.CaseModel},
        [pscustomobject]@{Label='Power supply';Value=$p.PsuModel},
        [pscustomobject]@{Label='PSU serial';Value=$p.PsuSerial},
        [pscustomobject]@{Label='CPU cooler';Value=$p.Cooler},
        [pscustomobject]@{Label='CPU 2D / ATPO';Value=$p.CpuAtpo},
        [pscustomobject]@{Label='Tamper seal #1';Value=$p.Seal1},
        [pscustomobject]@{Label='Tamper seal #2';Value=$p.Seal2}
    )

    $board=(@($h.Motherboard.Manufacturer,$h.Motherboard.Model)|Where-Object{Test-SitecPrintableValue $_}) -join ' '
    $system=ConvertTo-SitecCompactPairs @(
        [pscustomobject]@{Label='Computer name';Value=$h.ComputerName},
        [pscustomobject]@{Label='Motherboard';Value=$board},
        [pscustomobject]@{Label='Motherboard serial';Value=$h.Motherboard.SerialNumber},
        [pscustomobject]@{Label='CPU';Value=$h.CPU.Model},
        [pscustomobject]@{Label='Cores / logical processors';Value=("{0} / {1}" -f $h.CPU.Cores,$h.CPU.LogicalProcessors)},
        [pscustomobject]@{Label='BIOS';Value=$h.BIOS.Version},
        [pscustomobject]@{Label='BIOS date';Value=$h.BIOS.ReleaseDate},
        [pscustomobject]@{Label='Windows';Value=("{0} (Build {1})" -f $h.Windows.Caption,$h.Windows.Build)},
        [pscustomobject]@{Label='System UUID';Value=$h.SystemUUID}
    )

    $ram=ConvertTo-SitecCompactTable -Rows $h.Memory -Columns @(
        [pscustomobject]@{Label='Slot';Getter={param($x)$x.Slot}},[pscustomobject]@{Label='Manufacturer';Getter={param($x)$x.Manufacturer}},
        [pscustomobject]@{Label='Part number';Getter={param($x)$x.PartNumber}},[pscustomobject]@{Label='Serial';Getter={param($x)$x.SerialNumber}},
        [pscustomobject]@{Label='Capacity';Getter={param($x)if($x.CapacityGB){"$($x.CapacityGB) GB"}else{''}}},[pscustomobject]@{Label='Type';Getter={param($x)$x.Type}},
        [pscustomobject]@{Label='Speed';Getter={param($x)if($x.ConfiguredSpeedMHz){"$($x.ConfiguredSpeedMHz) MHz"}else{''}}},[pscustomobject]@{Label='Voltage';Getter={param($x)if($x.ConfiguredVoltage_mV){"$($x.ConfiguredVoltage_mV) mV"}else{''}}}
    )

    $storage=ConvertTo-SitecCompactTable -Rows $h.Storage -Columns @(
        [pscustomobject]@{Label='Model';Getter={param($x)$x.Model}},[pscustomobject]@{Label='Serial';Getter={param($x)$x.SerialNumber}},
        [pscustomobject]@{Label='Capacity';Getter={param($x)if($x.SizeGB){"$($x.SizeGB) GB"}else{''}}},[pscustomobject]@{Label='Firmware';Getter={param($x)$x.FirmwareVersion}},
        [pscustomobject]@{Label='Bus';Getter={param($x)$x.BusType}},[pscustomobject]@{Label='Health';Getter={param($x)$x.HealthStatus}},
        [pscustomobject]@{Label='Temp';Getter={param($x)if($x.Reliability -and $null -ne $x.Reliability.TemperatureC){"$($x.Reliability.TemperatureC) C"}else{''}}},
        [pscustomobject]@{Label='Wear';Getter={param($x)if($x.Reliability -and $null -ne $x.Reliability.WearPercent){"$($x.Reliability.WearPercent)%"}else{''}}}
    )

    $graphics=ConvertTo-SitecCompactTable -Rows $h.Graphics -Columns @(
        [pscustomobject]@{Label='Graphics';Getter={param($x)$x.Name}},[pscustomobject]@{Label='Driver';Getter={param($x)$x.DriverVersion}},[pscustomobject]@{Label='Status';Getter={param($x)$x.Status}}
    )
    $network=ConvertTo-SitecCompactTable -Rows $h.Network -Columns @(
        [pscustomobject]@{Label='Adapter';Getter={param($x)$x.InterfaceDescription}},[pscustomobject]@{Label='MAC';Getter={param($x)$x.MacAddress}}
    )

    $benchPairs=@()
    if ($b.WinSAT) {
        $benchPairs += [pscustomobject]@{Label='WinSAT';Value=$b.WinSAT.Status}
        $benchPairs += [pscustomobject]@{Label='CPU compression';Value=$(if($null -ne $b.WinSAT.CpuCompressionMBps){"$($b.WinSAT.CpuCompressionMBps) MB/s"}else{''})}
        $benchPairs += [pscustomobject]@{Label='Memory bandwidth';Value=$(if($null -ne $b.WinSAT.MemoryMBps){"$($b.WinSAT.MemoryMBps) MB/s"}else{''})}
    }
    if ($b.DiskSpd) {
        $benchPairs += [pscustomobject]@{Label='DiskSpd qualification';Value=$b.DiskSpd.Status}
        $benchPairs += [pscustomobject]@{Label='SSD sequential read';Value=$(if($null -ne $b.DiskSpd.SequentialReadMBps){"$($b.DiskSpd.SequentialReadMBps) MB/s"}else{''})}
        $benchPairs += [pscustomobject]@{Label='SSD sequential write';Value=$(if($null -ne $b.DiskSpd.SequentialWriteMBps){"$($b.DiskSpd.SequentialWriteMBps) MB/s"}else{''})}
        $benchPairs += [pscustomobject]@{Label='SSD 4K random read';Value=$(if($null -ne $b.DiskSpd.RandomReadIOPS){"$($b.DiskSpd.RandomReadIOPS) IOPS"}else{''})}
    }
    if ($b.WHEA) { $benchPairs += [pscustomobject]@{Label='WHEA hardware errors';Value=[string]$b.WHEA.Count} }
    $benchmark=ConvertTo-SitecCompactPairs $benchPairs

    $burnPairs=@()
    if ($stress -and $stress.Status -ne 'SKIPPED') {
        $burnPairs += [pscustomobject]@{Label='Burn-in status';Value=$stress.Status}
        $burnPairs += [pscustomobject]@{Label='Duration';Value=("{0} s" -f $stress.ActualSeconds)}
        if (-not [bool]$stress.TimedOut) {
            $burnPairs += [pscustomobject]@{Label='CPU duty / threads';Value=("{0}% / {1}" -f $stress.CpuStress.DutyPercent,$stress.CpuStress.Threads)}
            $burnPairs += [pscustomobject]@{Label='RAM allocated';Value=("{0} MB" -f $stress.MemoryVerification.AllocatedMB)}
            $burnPairs += [pscustomobject]@{Label='RAM verified / errors';Value=("{0} MB / {1}" -f $stress.MemoryVerification.VerifiedMB,$stress.MemoryVerification.Errors)}
            $burnPairs += [pscustomobject]@{Label='NVMe sustained read';Value=$(if($null -ne $stress.DiskStress.ReadMBps){"$($stress.DiskStress.ReadMBps) MB/s"}else{$stress.DiskStress.Status})}
            $burnPairs += [pscustomobject]@{Label='Graphics workload';Value=$stress.GraphicsStress.Status}
            if ($stress.Utilization) {
                $burnPairs += [pscustomobject]@{Label='CPU utilization avg / peak';Value=("{0}% / {1}%" -f $stress.Utilization.CPU.Average,$stress.Utilization.CPU.Peak)}
                $burnPairs += [pscustomobject]@{Label='RAM utilization avg / peak';Value=("{0}% / {1}%" -f $stress.Utilization.Memory.Average,$stress.Utilization.Memory.Peak)}
                $burnPairs += [pscustomobject]@{Label='Disk utilization avg / peak';Value=("{0}% / {1}%" -f $stress.Utilization.Disk.Average,$stress.Utilization.Disk.Peak)}
                $burnPairs += [pscustomobject]@{Label='GPU utilization avg / peak';Value=("{0}% / {1}%" -f $stress.Utilization.GPU.Average,$stress.Utilization.GPU.Peak)}
            }
        } else {
            $burnPairs += [pscustomobject]@{Label='Timeout';Value=$stress.Error}
        }
    }
    $burnin=ConvertTo-SitecCompactPairs $burnPairs

    $checks=@($Run.BenchmarkValidation.Checks)
    $checkTable=ConvertTo-SitecCompactTable -Rows $checks -Columns @(
        [pscustomobject]@{Label='QC check';Getter={param($x)$x.Name}},[pscustomobject]@{Label='Expected';Getter={param($x)$x.Expected}},
        [pscustomobject]@{Label='Actual';Getter={param($x)$x.Actual}},[pscustomobject]@{Label='Status';Getter={param($x)$x.Status}}
    )
    $failureNames=@($checks | Where-Object Status -eq 'FAIL' | Select-Object -ExpandProperty Name)
    $failureText=if($failureNames.Count){($failureNames -join '; ')}else{'None'}

    $hwid='';$manifestHash=''
    if ($Run.Security) {
        $hwid=[string]$Run.Security.HardwareIdentitySha256
        $manifestHash=[string]$Run.Security.Sha256
    }
    $securityText=if($Run.Security -and $Run.Security.Signed){'RSA/SHA-256 signed'}else{'SHA-256 evidence hash (unsigned)'}

    $html=@"
<!doctype html><html><head><meta charset="utf-8"><title>$(ConvertTo-SitecHtml $Run.AssetId) QC Certificate</title>
<style>
@page{size:A4;margin:0}*{box-sizing:border-box}html,body{margin:0;padding:0;background:#fff;font-family:Segoe UI,Arial,sans-serif;color:#18212b}.sheet{width:210mm;height:297mm;padding:8mm 9mm;overflow:hidden;page-break-after:always;break-after:page;background:#fff}.sheet:last-child{page-break-after:auto;break-after:auto}.head{height:19mm;display:flex;justify-content:space-between;align-items:center;border-bottom:2px solid #263746;padding-bottom:3mm;margin-bottom:3mm}.brand{font-size:21px;font-weight:800}.subtitle{font-size:10px;color:#65727d}.overall{font-size:20px;font-weight:800;padding:5px 12px;border-radius:7px}.pass{background:#e7f7ed;color:#147a39}.fail{background:#fdeaea;color:#b42318}.warn{background:#fff4d8;color:#946200}.meta{display:grid;grid-template-columns:repeat(4,1fr);gap:5px;margin-bottom:7px}.meta>div{border:1px solid #dce3e8;border-radius:5px;padding:5px}.k{font-size:8px;color:#62717d;text-transform:uppercase;display:block}.v{font-size:9.5px;font-weight:600;word-break:break-word}.sec{margin:5px 0 7px}.sec h2{font-size:11.5px;margin:0 0 4px;padding-bottom:2px;border-bottom:1px solid #dce3e8;color:#263746}.pairs{display:grid;grid-template-columns:1fr 1fr;gap:3px 8px}.pair{display:grid;grid-template-columns:38% 62%;border-bottom:1px solid #edf0f2;padding:2px 0}.pair .k{font-size:8px}.pair .v{font-size:8.8px}table{width:100%;border-collapse:collapse;table-layout:auto;font-size:7.8px}th,td{border-bottom:1px solid #e8ecef;padding:3px 4px;text-align:left;vertical-align:top;word-break:break-word}th{background:#f4f7f9;font-weight:700;color:#40505c}.hashbox{border:1px solid #cfd8df;border-radius:6px;padding:6px;margin:5px 0}.hashlabel{font-size:8px;color:#667;text-transform:uppercase}.hash{font-family:Consolas,monospace;font-size:8.5px;font-weight:700;word-break:break-all;line-height:1.25}.summaryline{font-size:9px;margin:3px 0}.footer{position:absolute;left:9mm;right:9mm;bottom:7mm;border-top:1px solid #dce3e8;padding-top:3px;font-size:7.5px;color:#667}.sheet{position:relative}@media print{html,body{width:210mm}.sheet{margin:0;box-shadow:none}}
</style></head><body>
<div class="sheet">
<div class="head"><div><div class="brand">$(ConvertTo-SitecHtml $Context.Settings.Reporting.CompanyName)</div><div class="subtitle">PC Assembly &amp; Hardware Identity Certificate - Page 1 of 2</div></div><div class="overall $statusClass">$(ConvertTo-SitecHtml $Run.OverallStatus)</div></div>
<div class="meta"><div><span class="k">Asset ID</span><span class="v">$(ConvertTo-SitecHtml $Run.AssetId)</span></div><div><span class="k">Profile</span><span class="v">$(ConvertTo-SitecHtml ($Run.Profile.ProfileId+' v'+$Run.Profile.ProfileVersion))</span></div><div><span class="k">Operator</span><span class="v">$(ConvertTo-SitecHtml $Run.Operator)</span></div><div><span class="k">Completed</span><span class="v">$(ConvertTo-SitecHtml $completed)</span></div></div>
<div class="sec"><h2>Assembly Identity</h2>$assembly</div>
<div class="sec"><h2>Detected System Hardware</h2>$system</div>
<div class="sec"><h2>Memory Modules</h2>$ram</div>
<div class="sec"><h2>Storage</h2>$storage</div>
<div class="sec"><h2>Graphics</h2>$graphics</div>
<div class="sec"><h2>Network Identity</h2>$network</div>
<div class="footer">Run ID: $(ConvertTo-SitecHtml $Run.RunId) | BOM validation: $(ConvertTo-SitecHtml $Run.BomValidation.Status)</div>
</div>
<div class="sheet">
<div class="head"><div><div class="brand">$(ConvertTo-SitecHtml $Context.Settings.Reporting.CompanyName)</div><div class="subtitle">Benchmark, Stability &amp; Evidence - Page 2 of 2</div></div><div class="overall $statusClass">$(ConvertTo-SitecHtml $Run.OverallStatus)</div></div>
<div class="sec"><h2>Performance Qualification</h2>$benchmark</div>
<div class="sec"><h2>Full System Burn-In</h2>$burnin</div>
<div class="sec"><h2>QC Validation</h2>$checkTable</div>
<div class="sec"><h2>Result</h2><div class="summaryline"><b>Overall:</b> $(ConvertTo-SitecHtml $Run.OverallStatus)</div><div class="summaryline"><b>Failing gates:</b> $(ConvertTo-SitecHtml $failureText)</div><div class="summaryline"><b>Evidence protection:</b> $(ConvertTo-SitecHtml $securityText)</div></div>
<div class="hashbox"><div class="hashlabel">Hardware Identity SHA-256</div><div class="hash">$(ConvertTo-SitecHtml $hwid)</div></div>
<div class="hashbox"><div class="hashlabel">Manifest SHA-256</div><div class="hash">$(ConvertTo-SitecHtml $manifestHash)</div></div>
<div class="footer">Asset: $(ConvertTo-SitecHtml $Run.AssetId) | Run ID: $(ConvertTo-SitecHtml $Run.RunId) | Generated by SITEC PC Assembly &amp; QC</div>
</div></body></html>
"@

    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8
    $pdf=$false
    if ($Context.Settings.Reporting.GeneratePdf) { $pdf=Convert-SitecHtmlToPdf -HtmlPath $reportPath -PdfPath $pdfPath }
    [pscustomobject]@{HtmlPath=$reportPath;PdfPath=$(if($pdf){$pdfPath}else{$null})}
}
