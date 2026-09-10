# Windows PowerShell 5.1 compatibility and production hardening overrides.
# This file intentionally loads last because Sitec.QC.psm1 imports function
# files alphabetically. Keep behavior covered by Runtime.Tests.ps1.

function New-SitecObjectTableSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyCollection()]$Rows,
        [Parameter(Mandatory)]$Columns
    )
    if ($null -eq $Rows) { return '' }
    $rowsArray=@($Rows | Where-Object { $null -ne $_ })
    if ($rowsArray.Count -eq 0) { return '' }

    $active=@()
    foreach ($column in $Columns) {
        $has=$false
        foreach ($row in $rowsArray) {
            $value=''
            try { $value=& $column.Getter $row } catch [System.Management.Automation.PropertyNotFoundException] { $value='' }
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
            $value=''
            try { $value=& $column.Getter $row } catch [System.Management.Automation.PropertyNotFoundException] { $value='' }
            $cells += '<td>'+(ConvertTo-SitecHtml $value)+'</td>'
        }
        $body += '<tr>'+$cells+'</tr>'
    }
    '<section><h2>'+(ConvertTo-SitecHtml $Title)+'</h2><table><thead>'+$head+'</thead><tbody>'+$body+'</tbody></table></section>'
}

function Get-SitecIdentityStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Hardware,$Profile=$null)

    $all=@($Hardware.Storage | Where-Object { $null -ne $_ })
    if ($null -ne $Profile -and $null -ne $Profile.Expected) {
        $expected=[string]$Profile.Expected.StorageModelContains
        if (-not [string]::IsNullOrWhiteSpace($expected)) {
            return @($all | Where-Object {
                ([string]$_.Model -like ('*'+$expected+'*')) -or
                ([string]$_.FriendlyName -like ('*'+$expected+'*'))
            })
        }
    }

    # A USB flash/external disk is evidence media, not part of the assembled PC.
    @($all | Where-Object { [string]$_.BusType -notmatch '^(USB|SD|MMC)$' })
}

function Get-SitecSerialSet {
    param($Hardware,$Physical,$Profile=$null)
    $rows=@()
    if (Test-SitecUsefulIdentifier $Hardware.Motherboard.SerialNumber) {
        $rows += [pscustomobject]@{Type='Motherboard';Serial=[string]$Hardware.Motherboard.SerialNumber}
    }
    foreach ($m in @($Hardware.Memory)) {
        if (Test-SitecUsefulIdentifier $m.SerialNumber) { $rows += [pscustomobject]@{Type='RAM';Serial=[string]$m.SerialNumber} }
    }
    foreach ($d in @(Get-SitecIdentityStorage -Hardware $Hardware -Profile $Profile)) {
        if (Test-SitecUsefulIdentifier $d.SerialNumber) { $rows += [pscustomobject]@{Type='Storage';Serial=[string]$d.SerialNumber} }
    }
    if (Test-SitecUsefulIdentifier $Physical.CpuAtpo) { $rows += [pscustomobject]@{Type='CPU-ATPO';Serial=[string]$Physical.CpuAtpo} }
    if (Test-SitecUsefulIdentifier $Physical.PsuSerial) { $rows += [pscustomobject]@{Type='PSU';Serial=[string]$Physical.PsuSerial} }
    if (Test-SitecUsefulIdentifier $Physical.Seal1) { $rows += [pscustomobject]@{Type='Seal';Serial=[string]$Physical.Seal1} }
    if (Test-SitecUsefulIdentifier $Physical.Seal2) { $rows += [pscustomobject]@{Type='Seal';Serial=[string]$Physical.Seal2} }

    @($rows | ForEach-Object {
        $_.Serial=([string]$_.Serial).Trim().ToUpperInvariant()
        $_
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Serial) })
}

function Find-SitecDuplicateSerials {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)]$Hardware,
        [Parameter(Mandatory)]$Physical,
        $Profile=$null
    )
    $index=Join-Path $DataRoot 'fleet-serial-index.csv'
    if (-not (Test-Path -LiteralPath $index)) { return @() }
    $existing=@(Import-Csv -LiteralPath $index -ErrorAction SilentlyContinue)
    $dups=@()
    foreach ($s in @(Get-SitecSerialSet -Hardware $Hardware -Physical $Physical -Profile $Profile)) {
        foreach ($hit in @($existing | Where-Object {
            $_.Type -eq $s.Type -and $_.Serial -eq $s.Serial -and $_.AssetId -ne $AssetId
        })) {
            $dups += [pscustomobject]@{
                Type=$s.Type;Serial=$s.Serial;ExistingAssetId=$hit.AssetId;ExistingRunId=$hit.RunId
            }
        }
    }
    @($dups)
}

function Update-SitecFleetIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)]$Run)
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    $serialIndex=Join-Path $DataRoot 'fleet-serial-index.csv'
    $runIndex=Join-Path $DataRoot 'fleet-runs.csv'
    $lockPath=Join-Path $DataRoot '.fleet-index.lock'
    $lock=$null
    for ($i=0;$i -lt 30;$i++) {
        try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $lock) { throw 'Could not acquire fleet index lock.' }
    try {
        $existing=@()
        if (Test-Path -LiteralPath $serialIndex) { $existing=@(Import-Csv -LiteralPath $serialIndex) }
        $existing=@($existing | Where-Object { $_.AssetId -ne $Run.AssetId })
        $new=@(Get-SitecSerialSet -Hardware $Run.Hardware -Physical $Run.Physical -Profile $Run.Profile | ForEach-Object {
            [pscustomobject]@{AssetId=$Run.AssetId;RunId=$Run.RunId;Type=$_.Type;Serial=$_.Serial;Timestamp=$Run.CompletedAt}
        })
        @($existing+$new) | Export-Csv -LiteralPath $serialIndex -NoTypeInformation -Encoding UTF8

        $runs=@()
        if (Test-Path -LiteralPath $runIndex) { $runs=@(Import-Csv -LiteralPath $runIndex) }
        $runs=@($runs | Where-Object { $_.AssetId -ne $Run.AssetId })
        $identityStorage=@((Get-SitecIdentityStorage -Hardware $Run.Hardware -Profile $Run.Profile) | Select-Object -ExpandProperty SerialNumber)
        $runs += [pscustomobject]@{
            AssetId=$Run.AssetId
            RunId=$Run.RunId
            Timestamp=$Run.CompletedAt
            ProfileId=$Run.Profile.ProfileId
            ProfileVersion=$Run.Profile.ProfileVersion
            OverallStatus=$Run.OverallStatus
            MotherboardSerial=$Run.Hardware.Motherboard.SerialNumber
            StorageSerials=($identityStorage -join '|')
            RamSerials=(@($Run.Hardware.Memory | Select-Object -ExpandProperty SerialNumber) -join '|')
            CpuAtpo=$Run.Physical.CpuAtpo
            PsuSerial=$Run.Physical.PsuSerial
            HardwareIdentitySha256=$(if($Run.Security.PSObject.Properties['HardwareIdentitySha256']){$Run.Security.HardwareIdentitySha256}else{''})
            ManifestSha256=$Run.Security.Sha256
        }
        $runs | Export-Csv -LiteralPath $runIndex -NoTypeInformation -Encoding UTF8
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

function Test-SitecExpectedBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Hardware,
        [Parameter(Mandatory)]$Physical,
        [Parameter(Mandatory)]$Profile
    )

    $e=$Profile.Expected
    $checks=@()
    $checks += New-SitecCheck 'Case model' ([string]$e.CaseModel) ([string]$Physical.CaseModel) ([string]$Physical.CaseModel -eq [string]$e.CaseModel)
    $checks += New-SitecCheck 'PSU model' ([string]$e.PsuModel) ([string]$Physical.PsuModel) ([string]$Physical.PsuModel -eq [string]$e.PsuModel)
    $checks += New-SitecCheck 'Motherboard model' ([string]$e.MotherboardModelContains) ([string]$Hardware.Motherboard.Model) ([string]$Hardware.Motherboard.Model -like ('*'+[string]$e.MotherboardModelContains+'*'))
    $checks += New-SitecCheck 'CPU model' ([string]$e.CpuModelContains) ([string]$Hardware.CPU.Model) ([string]$Hardware.CPU.Model -like ('*'+[string]$e.CpuModelContains+'*'))
    $checks += New-SitecCheck 'RAM total' ("$($e.MemoryTotalGB) GB") ("$($Hardware.MemoryTotalGB) GB") ([double]$Hardware.MemoryTotalGB -eq [double]$e.MemoryTotalGB)

    $ramTypes=@($Hardware.Memory | Select-Object -ExpandProperty Type -Unique)
    $checks += New-SitecCheck 'RAM type' ([string]$e.MemoryType) ($ramTypes -join ', ') ($ramTypes -contains [string]$e.MemoryType)
    $speedMeasurement=$Hardware.Memory | Measure-Object ConfiguredSpeedMHz -Minimum
    $minSpeed=if ($null -ne $speedMeasurement.Minimum) {[int]$speedMeasurement.Minimum}else{0}
    $checks += New-SitecCheck 'RAM configured speed' (">= $($e.MemoryMinimumConfiguredSpeedMHz) MHz") ("$minSpeed MHz") ($minSpeed -ge [int]$e.MemoryMinimumConfiguredSpeedMHz)

    $storage=@(Get-SitecIdentityStorage -Hardware $Hardware -Profile $Profile)
    $checks += New-SitecCheck 'Storage model' ([string]$e.StorageModelContains) (($storage | Select-Object -ExpandProperty Model) -join '; ') ($storage.Count -gt 0)
    $storageMeasurement=$storage | Measure-Object SizeGB -Maximum
    $largest=if ($null -ne $storageMeasurement.Maximum) {[double]$storageMeasurement.Maximum}else{0}
    $checks += New-SitecCheck 'Storage capacity' (">= $($e.StorageMinimumSizeGB) GB") ("$largest GB") ($largest -ge [double]$e.StorageMinimumSizeGB)

    if (-not [string]::IsNullOrWhiteSpace([string]$e.GpuModelContains)) {
        $gpuMatch=@($Hardware.Graphics | Where-Object { $_.Name -like ('*'+[string]$e.GpuModelContains+'*') })
        $checks += New-SitecCheck 'Graphics' ([string]$e.GpuModelContains) (($Hardware.Graphics | Select-Object -ExpandProperty Name) -join '; ') ($gpuMatch.Count -gt 0) 'Warning'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$e.CpuCoolerModel)) {
        $checks += New-SitecCheck 'CPU cooler' ([string]$e.CpuCoolerModel) ([string]$Physical.Cooler) ([string]$Physical.Cooler -eq [string]$e.CpuCoolerModel)
    }

    $capture=$Profile.Capture
    $requirePsuSerial=if ($null -eq $capture) {$true}else{[bool]$capture.RequirePsuSerial}
    $requireCpuAtpo=if ($null -eq $capture) {$true}else{[bool]$capture.RequireCpuAtpo}
    $requireSeal1=if ($null -eq $capture) {$true}else{[bool]$capture.RequireSeal1}
    $requireSeal2=if ($null -eq $capture) {$false}else{[bool]$capture.RequireSeal2}
    $ssdSerials=@($storage | Select-Object -ExpandProperty SerialNumber | Where-Object { Test-SitecUsefulIdentifier $_ })
    $ramSerials=@($Hardware.Memory | Select-Object -ExpandProperty SerialNumber | Where-Object { Test-SitecUsefulIdentifier $_ })

    $required=@(
        [pscustomobject]@{Name='Motherboard serial';Value=$Hardware.Motherboard.SerialNumber;Required=$true},
        [pscustomobject]@{Name='RAM serial';Value=($ramSerials -join ',');Required=$true},
        [pscustomobject]@{Name='SSD serial';Value=($ssdSerials -join ',');Required=$true},
        [pscustomobject]@{Name='CPU ATPO';Value=$Physical.CpuAtpo;Required=$requireCpuAtpo},
        [pscustomobject]@{Name='PSU serial';Value=$Physical.PsuSerial;Required=$requirePsuSerial},
        [pscustomobject]@{Name='Seal #1';Value=$Physical.Seal1;Required=$requireSeal1},
        [pscustomobject]@{Name='Seal #2';Value=$Physical.Seal2;Required=$requireSeal2}
    )
    foreach ($item in $required) {
        if (-not $item.Required) { continue }
        $actual=[string]$item.Value
        $ok=Test-SitecUsefulIdentifier $actual
        $checks += New-SitecCheck ([string]$item.Name) 'Present' $actual $ok
    }

    if (@($Hardware.PnPErrors).Count -gt 0) {
        $checks += New-SitecCheck 'PnP device errors' '0' ([string]@($Hardware.PnPErrors).Count) $false
    }
    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{Status=if($failed.Count -eq 0){'PASS'}else{'FAIL'};Checks=@($checks)}
}

function Get-SitecSensorSnapshot {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Settings.Sensors.Enabled) { return @() }
    $dll=Get-SitecLibreHardwareMonitorDll -Context $Context
    if (-not $dll) { return @() }

    $computer=$null
    try {
        if (-not ('LibreHardwareMonitor.Hardware.Computer' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        $computer=New-Object LibreHardwareMonitor.Hardware.Computer
        $computer.IsCpuEnabled=$true
        $computer.IsGpuEnabled=$true
        $computer.IsMemoryEnabled=$true
        $computer.IsMotherboardEnabled=$true
        $computer.IsStorageEnabled=$true
        $computer.Open()

        $rows=@()
        $pending=@($computer.Hardware)
        while ($pending.Count -gt 0) {
            $hw=$pending[0]
            if ($pending.Count -gt 1) { $pending=@($pending[1..($pending.Count-1)]) } else { $pending=@() }
            $hw.Update()
            foreach ($s in @($hw.Sensors)) {
                if ($null -ne $s.Value) {
                    $rows += [pscustomobject]@{
                        Hardware=[string]$hw.Name
                        HardwareType=[string]$hw.HardwareType
                        Sensor=[string]$s.Name
                        SensorType=[string]$s.SensorType
                        Value=[double]$s.Value
                        Min=$(if($null -ne $s.Min){[double]$s.Min}else{$null})
                        Max=$(if($null -ne $s.Max){[double]$s.Max}else{$null})
                    }
                }
            }
            foreach ($sub in @($hw.SubHardware)) { if ($null -ne $sub) { $pending += $sub } }
        }
        @($rows)
    } catch {
        @()
    } finally {
        if ($null -ne $computer) { try { $computer.Close() } catch {} }
    }
}

function Invoke-SitecStress {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    Initialize-SitecStressType
    $cpuSeconds=[int]$Context.Settings.Stress.CpuSeconds
    $memMb=[int]$Context.Settings.Stress.MemoryTestMB
    $snapshots=@()
    $task=[SitecQcStress]::CpuAsync($cpuSeconds,[Environment]::ProcessorCount)
    while (-not $task.IsCompleted) {
        $sample=@(Get-SitecSensorSnapshot -Context $Context)
        if ($sample.Count -gt 0) { $snapshots += $sample }
        Start-Sleep -Seconds ([math]::Max([int]$Context.Settings.Sensors.SampleIntervalSeconds,1))
    }
    $cpu=$task.GetAwaiter().GetResult()
    $memory=[SitecQcStress]::MemoryVerify($memMb)
    $sample=@(Get-SitecSensorSnapshot -Context $Context)
    if ($sample.Count -gt 0) { $snapshots += $sample }
    $summary=@(Get-SitecSensorSummary -Snapshots $snapshots)

    [pscustomobject]@{
        Status=if($memory.Errors -eq 0){'PASS'}else{'FAIL'}
        CpuStress=[pscustomobject]@{
            Seconds=$cpuSeconds;Threads=$cpu.Threads;HashWorkMBps=[math]::Round($cpu.MegabytesPerSecond,2);Iterations=$cpu.Iterations
        }
        MemoryVerification=[pscustomobject]@{
            RequestedMB=$memMb;VerifiedMB=[math]::Round([double]$memory.BytesVerified/1MB,0);Errors=$memory.Errors;Seconds=[math]::Round($memory.Seconds,2)
        }
        Sensors=@($summary)
    }
}

function Convert-SitecInvariantDouble {
    param($Value)
    if ($null -eq $Value) { return [double]0 }
    $s=[string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return [double]0 }
    [double]::Parse($s,[Globalization.CultureInfo]::InvariantCulture)
}

function Get-DiskSpdMetrics {
    param([Parameter(Mandatory)][string]$XmlPath)
    [xml]$x=Get-Content -LiteralPath $XmlPath -Raw -ErrorAction Stop
    $timeNode=$x.SelectSingleNode('/Results/TimeSpan/TestTimeSeconds')
    if ($null -eq $timeNode) { throw 'DiskSpd XML does not contain TestTimeSeconds.' }
    $ts=Convert-SitecInvariantDouble $timeNode.InnerText
    if ($ts -le 0) { throw 'DiskSpd XML contains an invalid test duration.' }

    $targets=@($x.SelectNodes('/Results/TimeSpan/Thread/Target'))
    if ($targets.Count -eq 0) { throw 'DiskSpd XML does not contain thread targets.' }

    [double]$readCount=0;[double]$writeCount=0;[double]$readBytes=0;[double]$writeBytes=0
    [double]$readLatencyWeighted=0;[double]$writeLatencyWeighted=0
    foreach ($target in $targets) {
        $rc=Convert-SitecInvariantDouble $target.ReadCount
        $wc=Convert-SitecInvariantDouble $target.WriteCount
        $rb=Convert-SitecInvariantDouble $target.ReadBytes
        $wb=Convert-SitecInvariantDouble $target.WriteBytes
        $readCount += $rc; $writeCount += $wc; $readBytes += $rb; $writeBytes += $wb
        if ($rc -gt 0 -and $target.AverageReadLatencyMilliseconds) {
            $readLatencyWeighted += (Convert-SitecInvariantDouble $target.AverageReadLatencyMilliseconds) * $rc
        }
        if ($wc -gt 0 -and $target.AverageWriteLatencyMilliseconds) {
            $writeLatencyWeighted += (Convert-SitecInvariantDouble $target.AverageWriteLatencyMilliseconds) * $wc
        }
    }

    [pscustomobject]@{
        TestTimeSeconds=$ts
        ReadIOPS=[math]::Round($readCount/$ts,2)
        WriteIOPS=[math]::Round($writeCount/$ts,2)
        ReadMBps=[math]::Round(($readBytes/$ts)/1MB,2)
        WriteMBps=[math]::Round(($writeBytes/$ts)/1MB,2)
        AverageReadLatencyMs=$(if($readCount -gt 0){[math]::Round($readLatencyWeighted/$readCount,3)}else{$null})
        AverageWriteLatencyMs=$(if($writeCount -gt 0){[math]::Round($writeLatencyWeighted/$writeCount,3)}else{$null})
    }
}
