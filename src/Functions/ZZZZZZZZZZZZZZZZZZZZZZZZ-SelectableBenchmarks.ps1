# Operator-selectable benchmark components.
# Loaded last so benchmark orchestration/validation can honor the GUI selection
# while retaining the existing burn-in watchdog and production worker.

function Get-SitecBenchmarkSelection {
    [CmdletBinding()]
    param()

    $allowed=@('CPU','Memory','Disk','Graphics')
    $raw=[string]$env:SITECQC_BENCHMARK_COMPONENTS
    if ([string]::IsNullOrWhiteSpace($raw)) { return @($allowed) }

    $requested=@($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    @($allowed | Where-Object { $_ -in $requested })
}

function Test-SitecBenchmarkComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    @((Get-SitecBenchmarkSelection)) -contains $Name
}

function Invoke-SitecSelectedWinSat {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)

    $cpuEnabled=Test-SitecBenchmarkComponent -Name 'CPU'
    $memoryEnabled=Test-SitecBenchmarkComponent -Name 'Memory'
    if (-not $cpuEnabled -and -not $memoryEnabled) {
        return [pscustomobject]@{
            Available=$false;Status='SKIPPED';CpuStatus='SKIPPED';MemoryStatus='SKIPPED'
            CpuCompressionMBps=$null;MemoryMBps=$null;CpuExitCode=$null;MemoryExitCode=$null
        }
    }

    if (-not $Context.Settings.WinSAT.Enabled -or -not (Get-Command winsat.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Available=$false;Status='UNAVAILABLE'
            CpuStatus=$(if($cpuEnabled){'UNAVAILABLE'}else{'SKIPPED'})
            MemoryStatus=$(if($memoryEnabled){'UNAVAILABLE'}else{'SKIPPED'})
            CpuCompressionMBps=$null;MemoryMBps=$null;CpuExitCode=$null;MemoryExitCode=$null
        }
    }

    $benchDir=Join-Path $RunPath 'benchmark\winsat'
    New-Item -ItemType Directory -Path $benchDir -Force | Out-Null
    $cpuMetric=$null;$memMetric=$null;$cpuExit=$null;$memExit=$null
    $cpuStatus=if($cpuEnabled){'FAIL'}else{'SKIPPED'}
    $memStatus=if($memoryEnabled){'FAIL'}else{'SKIPPED'}

    if ($cpuEnabled) {
        $cpuXml=Join-Path $benchDir 'cpu.xml'
        try {
            $cpu=Invoke-SitecProcess -FilePath 'winsat.exe' -Arguments "cpu -compression -xml `"$cpuXml`"" -StdOutPath (Join-Path $benchDir 'cpu.out.txt') -StdErrPath (Join-Path $benchDir 'cpu.err.txt') -TimeoutSeconds 120
            $cpuExit=$cpu.ExitCode
            $cpuStatus=if($cpu.ExitCode -eq 0){'PASS'}else{'FAIL'}
            $cpuMetric=Get-WinSatMetricFromXml -Path $cpuXml -XPath '//CPUMetrics/CompressionMetric'
            if ($null -eq $cpuMetric) { $cpuMetric=Get-WinSatMetricFromXml -Path $cpuXml -XPath '//CPUCompressionAssessment/Metric' }
        } catch {
            $cpuStatus='FAIL'
        }
    }

    if ($memoryEnabled) {
        $memXml=Join-Path $benchDir 'memory.xml'
        try {
            $mem=Invoke-SitecProcess -FilePath 'winsat.exe' -Arguments "mem -mint 3 -maxt 8 -xml `"$memXml`"" -StdOutPath (Join-Path $benchDir 'memory.out.txt') -StdErrPath (Join-Path $benchDir 'memory.err.txt') -TimeoutSeconds 120
            $memExit=$mem.ExitCode
            $memStatus=if($mem.ExitCode -eq 0){'PASS'}else{'FAIL'}
            $memMetric=Get-WinSatMetricFromXml -Path $memXml -XPath '//MemoryMetrics/Bandwidth'
            if ($null -eq $memMetric) { $memMetric=Get-WinSatMetricFromXml -Path $memXml -XPath '//SystemMemoryBandwidth/Metric' }
            if ($null -eq $memMetric) {
                try {
                    [xml]$mx=Get-Content -LiteralPath $memXml -Raw
                    $n=$mx.SelectSingleNode('//*[contains(local-name(),"Bandwidth") and text()]')
                    if ($n) { $memMetric=[double]::Parse($n.InnerText,[Globalization.CultureInfo]::InvariantCulture) }
                } catch {}
            }
        } catch {
            $memStatus='FAIL'
        }
    }

    $selectedStatuses=@()
    if($cpuEnabled){$selectedStatuses+=$cpuStatus}
    if($memoryEnabled){$selectedStatuses+=$memStatus}
    [pscustomobject]@{
        Available=$true
        Status=if(@($selectedStatuses | Where-Object { $_ -ne 'PASS' }).Count -eq 0){'PASS'}else{'FAIL'}
        CpuStatus=$cpuStatus
        MemoryStatus=$memStatus
        CpuCompressionMBps=$cpuMetric
        MemoryMBps=$memMetric
        CpuExitCode=$cpuExit
        MemoryExitCode=$memExit
    }
}

function Invoke-SitecBenchmarkSuite {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)

    $selection=@(Get-SitecBenchmarkSelection)
    $started=Get-Date

    if ((Test-SitecBenchmarkComponent -Name 'CPU') -or (Test-SitecBenchmarkComponent -Name 'Memory')) {
        Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 30 -Message ('Performance qualification: '+(($selection | Where-Object { $_ -in @('CPU','Memory') }) -join ' + '))
    }
    try {
        $winsat=Invoke-SitecSelectedWinSat -Context $Context -RunPath $RunPath
    } catch {
        $winsat=[pscustomobject]@{
            Available=$true;Status='FAIL'
            CpuStatus=$(if(Test-SitecBenchmarkComponent -Name 'CPU'){'FAIL'}else{'SKIPPED'})
            MemoryStatus=$(if(Test-SitecBenchmarkComponent -Name 'Memory'){'FAIL'}else{'SKIPPED'})
            CpuCompressionMBps=$null;MemoryMBps=$null;Error=$_.Exception.Message
        }
    }

    if (Test-SitecBenchmarkComponent -Name 'Disk') {
        Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 35 -Message 'Performance qualification: storage throughput and IOPS'
        try {
            $disk=Invoke-SitecDiskSpd -Context $Context -RunPath $RunPath
        } catch {
            $disk=[pscustomobject]@{Available=$true;Required=[bool]$Context.Settings.DiskSpd.Enabled;Status='FAIL';SequentialReadMBps=$null;SequentialWriteMBps=$null;RandomReadIOPS=$null;Error=$_.Exception.Message}
        }
    } else {
        $disk=[pscustomobject]@{Available=$false;Required=$false;Status='SKIPPED';SequentialReadMBps=$null;SequentialWriteMBps=$null;RandomReadIOPS=$null}
    }

    Set-SitecBurnInUiProgress -RunPath $RunPath -Percent 40 -Message ('Starting selected burn-in: '+($selection -join ' + '))
    try {
        $burn=Invoke-SitecFullSystemBurnIn -Context $Context -RunPath $RunPath
    } catch {
        $burn=[pscustomobject]@{
            Status='FAIL';Required=$true;Error=$_.Exception.Message;DurationSeconds=0;ActualSeconds=0;Selection=@($selection)
            CpuStress=[pscustomobject]@{Enabled=(Test-SitecBenchmarkComponent -Name 'CPU');Status='FAIL';Seconds=0;Threads=0;DutyPercent=0;HashWorkMBps=0;WorkUnitsPerSecond=0;Iterations=0}
            MemoryVerification=[pscustomobject]@{Enabled=(Test-SitecBenchmarkComponent -Name 'Memory');Status='FAIL';RequestedMB=0;AllocatedMB=0;VerifiedMB=0;Errors=[long]::MaxValue;Seconds=0;Passes=0}
            DiskStress=[pscustomobject]@{Enabled=(Test-SitecBenchmarkComponent -Name 'Disk');Status='FAIL';ReadMBps=$null;ReadIOPS=$null;AverageReadLatencyMs=$null}
            GraphicsStress=[pscustomobject]@{Enabled=(Test-SitecBenchmarkComponent -Name 'Graphics');Required=$false;Status='FAIL';Engine='WinSAT DWM composition workload'}
            Utilization=(Get-SitecLoadSummary @());Sensors=@();LoadSamples=@()
        }
    }

    $whea=Get-SitecWheaEvents -Since $started
    [pscustomobject]@{
        Selection=@($selection)
        StartedAt=$started.ToString('o')
        FinishedAt=(Get-Date).ToString('o')
        WinSAT=$winsat
        DiskSpd=$disk
        BurnIn=$burn
        Stress=$burn
        WHEA=[pscustomobject]@{Count=@($whea).Count;Events=@($whea)}
    }
}

function Test-SitecBenchmarkResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Benchmark,[Parameter(Mandatory)]$Profile)

    $selection=if($Benchmark.PSObject.Properties['Selection'] -and @($Benchmark.Selection).Count -gt 0){@($Benchmark.Selection)}else{@('CPU','Memory','Disk','Graphics')}
    function Selected([string]$Name){ return ($selection -contains $Name) }

    $t=$Profile.Thresholds
    $checks=@()
    $burn=$null
    if ($Benchmark.PSObject.Properties['BurnIn']) { $burn=$Benchmark.BurnIn }
    elseif ($Benchmark.PSObject.Properties['Stress']) { $burn=$Benchmark.Stress }

    if ($burn) {
        $checks += New-SitecCheck 'Selected hardware burn-in' 'PASS' ([string]$burn.Status) ([string]$burn.Status -eq 'PASS')

        if (Selected 'Memory') {
            $checks += New-SitecCheck 'Memory verification errors' ("<= $($t.MaximumMemoryVerificationErrors)") ([string]$burn.MemoryVerification.Errors) ([long]$burn.MemoryVerification.Errors -le [long]$t.MaximumMemoryVerificationErrors)

            if ($burn.MemoryVerification.PSObject.Properties['AllocationCoveragePercent'] -and $t.PSObject.Properties['MinimumBurnInMemoryPlanCoveragePercent']) {
                $coverage=[double]$burn.MemoryVerification.AllocationCoveragePercent
                $checks += New-SitecCheck 'RAM safe allocation coverage' (">= $($t.MinimumBurnInMemoryPlanCoveragePercent)%") ("$coverage%") ($coverage -ge [double]$t.MinimumBurnInMemoryPlanCoveragePercent)
            }
        }

        if ((Selected 'Disk') -and $burn.PSObject.Properties['DiskStress'] -and $burn.DiskStress.Enabled) {
            $checks += New-SitecCheck 'Burn-in NVMe workload' 'PASS' ([string]$burn.DiskStress.Status) ([string]$burn.DiskStress.Status -eq 'PASS')
            if ($null -ne $burn.DiskStress.ReadMBps -and $t.PSObject.Properties['MinimumBurnInDiskReadMBps']) {
                $checks += New-SitecCheck 'Burn-in NVMe throughput' (">= $($t.MinimumBurnInDiskReadMBps) MB/s") ("$($burn.DiskStress.ReadMBps) MB/s") ([double]$burn.DiskStress.ReadMBps -ge [double]$t.MinimumBurnInDiskReadMBps)
            }
        }

        if ((Selected 'Graphics') -and $burn.PSObject.Properties['GraphicsStress'] -and $burn.GraphicsStress.Enabled) {
            $severity=if($burn.GraphicsStress.Required){'Error'}else{'Warning'}
            $checks += New-SitecCheck 'Graphics burn-in workload' 'PASS' ([string]$burn.GraphicsStress.Status) ([string]$burn.GraphicsStress.Status -eq 'PASS') $severity
        }

        if ($burn.PSObject.Properties['Utilization']) {
            if ((Selected 'CPU') -and $null -ne $burn.Utilization.CPU.Average -and $t.PSObject.Properties['MinimumBurnInCpuAveragePercent']) {
                $checks += New-SitecCheck 'CPU average load during burn-in' (">= $($t.MinimumBurnInCpuAveragePercent)%") ("$($burn.Utilization.CPU.Average)%") ([double]$burn.Utilization.CPU.Average -ge [double]$t.MinimumBurnInCpuAveragePercent)
            }
            if ((Selected 'Memory') -and $null -ne $burn.Utilization.Memory.Peak) {
                if ($burn.MemoryVerification.PSObject.Properties['ExpectedSystemUsagePercent'] -and $null -ne $burn.MemoryVerification.ExpectedSystemUsagePercent -and $t.PSObject.Properties['MaximumBurnInMemoryPeakShortfallPercent']) {
                    $expectedPeak=[double]$burn.MemoryVerification.ExpectedSystemUsagePercent
                    $allowedShortfall=[double]$t.MaximumBurnInMemoryPeakShortfallPercent
                    $requiredPeak=[math]::Max(0,[math]::Round($expectedPeak-$allowedShortfall,1))
                    $checks += New-SitecCheck 'Peak RAM use during burn-in' (">= $requiredPeak% ($expectedPeak% planned, <= $allowedShortfall pp shortfall)") ("$($burn.Utilization.Memory.Peak)%") ([double]$burn.Utilization.Memory.Peak -ge $requiredPeak)
                } elseif ($t.PSObject.Properties['MinimumBurnInMemoryPeakPercent']) {
                    $checks += New-SitecCheck 'Peak RAM use during burn-in' (">= $($t.MinimumBurnInMemoryPeakPercent)%") ("$($burn.Utilization.Memory.Peak)%") ([double]$burn.Utilization.Memory.Peak -ge [double]$t.MinimumBurnInMemoryPeakPercent)
                }
            }
            if ((Selected 'Graphics') -and $null -ne $burn.Utilization.GPU.Peak -and $t.PSObject.Properties['MinimumBurnInGpuPeakPercent']) {
                $checks += New-SitecCheck 'GPU peak load during burn-in' (">= $($t.MinimumBurnInGpuPeakPercent)%") ("$($burn.Utilization.GPU.Peak)%") ([double]$burn.Utilization.GPU.Peak -ge [double]$t.MinimumBurnInGpuPeakPercent) 'Warning'
            }
        }
    }

    $checks += New-SitecCheck 'WHEA hardware errors' ("<= $($t.MaximumWheaEvents)") ([string]$Benchmark.WHEA.Count) ([int]$Benchmark.WHEA.Count -le [int]$t.MaximumWheaEvents)

    if (Selected 'CPU') {
        if ($Benchmark.WinSAT.Available) {
            $cpuStatus=if($Benchmark.WinSAT.PSObject.Properties['CpuStatus']){[string]$Benchmark.WinSAT.CpuStatus}else{[string]$Benchmark.WinSAT.Status}
            $checks += New-SitecCheck 'WinSAT CPU execution' 'PASS' $cpuStatus ($cpuStatus -eq 'PASS')
            if ($null -ne $Benchmark.WinSAT.CpuCompressionMBps) {
                $checks += New-SitecCheck 'CPU compression' (">= $($t.MinimumWinSatCpuCompressionMBps) MB/s") ("$($Benchmark.WinSAT.CpuCompressionMBps) MB/s") ([double]$Benchmark.WinSAT.CpuCompressionMBps -ge [double]$t.MinimumWinSatCpuCompressionMBps) 'Warning'
            }
        } else {
            $checks += New-SitecCheck 'WinSAT CPU availability' 'Available' ([string]$Benchmark.WinSAT.Status) $false 'Warning'
        }
    }

    if (Selected 'Memory') {
        if ($Benchmark.WinSAT.Available) {
            $memStatus=if($Benchmark.WinSAT.PSObject.Properties['MemoryStatus']){[string]$Benchmark.WinSAT.MemoryStatus}else{[string]$Benchmark.WinSAT.Status}
            $checks += New-SitecCheck 'WinSAT memory execution' 'PASS' $memStatus ($memStatus -eq 'PASS')
            if ($null -ne $Benchmark.WinSAT.MemoryMBps) {
                $checks += New-SitecCheck 'Memory bandwidth' (">= $($t.MinimumWinSatMemoryMBps) MB/s") ("$($Benchmark.WinSAT.MemoryMBps) MB/s") ([double]$Benchmark.WinSAT.MemoryMBps -ge [double]$t.MinimumWinSatMemoryMBps) 'Warning'
            }
        } else {
            $checks += New-SitecCheck 'WinSAT memory availability' 'Available' ([string]$Benchmark.WinSAT.Status) $false 'Warning'
        }
    }

    if (Selected 'Disk') {
        if ($Benchmark.DiskSpd.Available) {
            $checks += New-SitecCheck 'DiskSpd execution' 'PASS' ([string]$Benchmark.DiskSpd.Status) ([string]$Benchmark.DiskSpd.Status -eq 'PASS')
            if ($null -ne $Benchmark.DiskSpd.SequentialReadMBps) {
                $checks += New-SitecCheck 'SSD sequential read' (">= $($t.MinimumDiskSpdSeqReadMBps) MB/s") ("$($Benchmark.DiskSpd.SequentialReadMBps) MB/s") ([double]$Benchmark.DiskSpd.SequentialReadMBps -ge [double]$t.MinimumDiskSpdSeqReadMBps)
            }
            if ($null -ne $Benchmark.DiskSpd.SequentialWriteMBps) {
                $checks += New-SitecCheck 'SSD sequential write' (">= $($t.MinimumDiskSpdSeqWriteMBps) MB/s") ("$($Benchmark.DiskSpd.SequentialWriteMBps) MB/s") ([double]$Benchmark.DiskSpd.SequentialWriteMBps -ge [double]$t.MinimumDiskSpdSeqWriteMBps)
            }
            if ($null -ne $Benchmark.DiskSpd.RandomReadIOPS) {
                $checks += New-SitecCheck 'SSD 4K random read' (">= $($t.MinimumDiskSpdRandomReadIOPS) IOPS") ("$($Benchmark.DiskSpd.RandomReadIOPS) IOPS") ([double]$Benchmark.DiskSpd.RandomReadIOPS -ge [double]$t.MinimumDiskSpdRandomReadIOPS)
            }
        } else {
            $severity=if($Benchmark.DiskSpd.PSObject.Properties['Required'] -and $Benchmark.DiskSpd.Required){'Error'}else{'Warning'}
            $checks += New-SitecCheck 'DiskSpd availability' 'Installed' ([string]$Benchmark.DiskSpd.Status) $false $severity
        }
    }

    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{Status=if($failed.Count -eq 0){'PASS'}else{'FAIL'};Checks=@($checks)}
}

function Add-SitecBurnInSummaryToCertificate {
    param([Parameter(Mandatory)][string]$RunPath)

    $manifestPath=Join-Path $RunPath 'hardware-qc-manifest.json'
    $htmlPath=Join-Path $RunPath 'QC-Certificate.html'
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $htmlPath)) { return $false }

    try {
        $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $m.Benchmark -or -not $m.Benchmark.PSObject.Properties['BurnIn']) { return $false }
        $b=$m.Benchmark.BurnIn
        if (-not $b -or [string]$b.Status -eq 'SKIPPED') { return $false }
        $selection=if($m.Benchmark.PSObject.Properties['Selection']){@($m.Benchmark.Selection)}else{@('CPU','Memory','Disk','Graphics')}

        $display=@($selection | ForEach-Object { if($_ -eq 'Memory'){'RAM'}elseif($_ -eq 'Disk'){'NVMe / Storage'}elseif($_ -eq 'Graphics'){'Graphics / GPU'}else{$_} })
        $rows=@()
        $rows += '<tr><th>Selected tests</th><td>'+ (ConvertTo-SitecHtml ($display -join ' + ')) +'</td><th>Status</th><td><b>'+ (ConvertTo-SitecHtml $b.Status) +'</b></td></tr>'
        $rows += '<tr><th>Duration</th><td>'+ (ConvertTo-SitecHtml ("$($b.ActualSeconds) s")) +'</td><th>Selection source</th><td>Operator</td></tr>'

        if ($selection -contains 'CPU') {
            $rows += '<tr><th>CPU burn-in</th><td>'+ (ConvertTo-SitecHtml $b.CpuStress.Status) +'</td><th>CPU duty / threads</th><td>'+ (ConvertTo-SitecHtml ("$($b.CpuStress.DutyPercent)% / $($b.CpuStress.Threads)")) +'</td></tr>'
        }
        if ($selection -contains 'Memory') {
            $rows += '<tr><th>RAM burn-in</th><td>'+ (ConvertTo-SitecHtml $b.MemoryVerification.Status) +'</td><th>RAM verified / errors</th><td>'+ (ConvertTo-SitecHtml ("$($b.MemoryVerification.VerifiedMB) MB / $($b.MemoryVerification.Errors)")) +'</td></tr>'
        }
        if ($selection -contains 'Disk') {
            $rows += '<tr><th>NVMe burn-in</th><td>'+ (ConvertTo-SitecHtml $b.DiskStress.Status) +'</td><th>Sustained read</th><td>'+ (ConvertTo-SitecHtml ($(if($null -ne $b.DiskStress.ReadMBps){"$($b.DiskStress.ReadMBps) MB/s"}else{'No metric'}))) +'</td></tr>'
        }
        if ($selection -contains 'Graphics') {
            $rows += '<tr><th>Graphics burn-in</th><td>'+ (ConvertTo-SitecHtml $b.GraphicsStress.Status) +'</td><th>Engine</th><td>'+ (ConvertTo-SitecHtml $b.GraphicsStress.Engine) +'</td></tr>'
        }
        if ($b.Utilization) {
            if ($selection -contains 'CPU') {
                $cpu="Avg $($b.Utilization.CPU.Average)% / Peak $($b.Utilization.CPU.Peak)%"
                $rows += '<tr><th>CPU utilization</th><td colspan="3">'+(ConvertTo-SitecHtml $cpu)+'</td></tr>'
            }
            if ($selection -contains 'Memory') {
                $ram="Avg $($b.Utilization.Memory.Average)% / Peak $($b.Utilization.Memory.Peak)%"
                $rows += '<tr><th>RAM utilization</th><td colspan="3">'+(ConvertTo-SitecHtml $ram)+'</td></tr>'
            }
            if ($selection -contains 'Disk') {
                $disk="Avg $($b.Utilization.Disk.Average)% / Peak $($b.Utilization.Disk.Peak)%"
                $rows += '<tr><th>Disk utilization</th><td colspan="3">'+(ConvertTo-SitecHtml $disk)+'</td></tr>'
            }
            if ($selection -contains 'Graphics') {
                $gpu="Avg $($b.Utilization.GPU.Average)% / Peak $($b.Utilization.GPU.Peak)%"
                $rows += '<tr><th>GPU utilization</th><td colspan="3">'+(ConvertTo-SitecHtml $gpu)+'</td></tr>'
            }
        }

        $section='<section><h2>Full System Burn-In</h2><table><tbody>'+($rows -join '')+'</tbody></table></section>'
        $html=Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
        if ($html -match '<h2>Full System Burn-In</h2>') { return $false }
        $html=$html.Replace('<div class="footer">',$section+'<div class="footer">')
        Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}
