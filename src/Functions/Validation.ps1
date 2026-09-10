function New-SitecCheck {
    param([string]$Name,[string]$Expected,[string]$Actual,[bool]$Passed,[string]$Severity='Error')
    [pscustomobject]@{
        Name=$Name
        Expected=$Expected
        Actual=$Actual
        Passed=$Passed
        Severity=$Severity
        Status=if ($Passed) {'PASS'} elseif ($Severity -eq 'Warning') {'WARNING'} else {'FAIL'}
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
    $checks=New-Object System.Collections.Generic.List[object]

    $checks.Add((New-SitecCheck 'Case model' $e.CaseModel $Physical.CaseModel ($Physical.CaseModel -eq $e.CaseModel)))
    $checks.Add((New-SitecCheck 'PSU model' $e.PsuModel $Physical.PsuModel ($Physical.PsuModel -eq $e.PsuModel)))
    $checks.Add((New-SitecCheck 'Motherboard model' $e.MotherboardModelContains $Hardware.Motherboard.Model ($Hardware.Motherboard.Model -like "*$($e.MotherboardModelContains)*")))
    $checks.Add((New-SitecCheck 'CPU model' $e.CpuModelContains $Hardware.CPU.Model ($Hardware.CPU.Model -like "*$($e.CpuModelContains)*")))
    $checks.Add((New-SitecCheck 'RAM total' "$($e.MemoryTotalGB) GB" "$($Hardware.MemoryTotalGB) GB" ([double]$Hardware.MemoryTotalGB -eq [double]$e.MemoryTotalGB)))

    $ramTypes=@($Hardware.Memory | Select-Object -ExpandProperty Type -Unique)
    $checks.Add((New-SitecCheck 'RAM type' $e.MemoryType ($ramTypes -join ', ') ($ramTypes -contains $e.MemoryType)))
    $minSpeed=[int](($Hardware.Memory | Measure-Object ConfiguredSpeedMHz -Minimum).Minimum)
    $checks.Add((New-SitecCheck 'RAM configured speed' ">= $($e.MemoryMinimumConfiguredSpeedMHz) MHz" "$minSpeed MHz" ($minSpeed -ge [int]$e.MemoryMinimumConfiguredSpeedMHz)))

    $storage=@($Hardware.Storage | Where-Object { $_.Model -like "*$($e.StorageModelContains)*" -or $_.FriendlyName -like "*$($e.StorageModelContains)*" })
    $checks.Add((New-SitecCheck 'Storage model' $e.StorageModelContains (($Hardware.Storage | Select-Object -ExpandProperty Model) -join '; ') ($storage.Count -gt 0)))
    $largest=[double](($Hardware.Storage | Measure-Object SizeGB -Maximum).Maximum)
    $checks.Add((New-SitecCheck 'Storage capacity' ">= $($e.StorageMinimumSizeGB) GB" "$largest GB" ($largest -ge [double]$e.StorageMinimumSizeGB)))

    if ($e.GpuModelContains) {
        $gpuMatch=@($Hardware.Graphics | Where-Object { $_.Name -like "*$($e.GpuModelContains)*" })
        $checks.Add((New-SitecCheck 'Graphics' $e.GpuModelContains (($Hardware.Graphics | Select-Object -ExpandProperty Name) -join '; ') ($gpuMatch.Count -gt 0) 'Warning'))
    }

    foreach ($required in @(
        @{Name='Motherboard serial';Value=$Hardware.Motherboard.SerialNumber},
        @{Name='RAM serial';Value=(($Hardware.Memory | Select-Object -ExpandProperty SerialNumber) -join ',')},
        @{Name='SSD serial';Value=(($Hardware.Storage | Select-Object -ExpandProperty SerialNumber) -join ',')},
        @{Name='CPU ATPO';Value=$Physical.CpuAtpo},
        @{Name='PSU serial';Value=$Physical.PsuSerial},
        @{Name='Seal #1';Value=$Physical.Seal1}
    )) {
        $ok=-not [string]::IsNullOrWhiteSpace([string]$required.Value)
        $checks.Add((New-SitecCheck $required.Name 'Present' ([string]$required.Value) $ok))
    }

    if (@($Hardware.PnPErrors).Count -gt 0) {
        $checks.Add((New-SitecCheck 'PnP device errors' '0' ([string]@($Hardware.PnPErrors).Count) $false))
    }

    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{ Status=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}; Checks=@($checks) }
}

function Test-SitecBenchmarkResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Benchmark,[Parameter(Mandatory)]$Profile)
    $t=$Profile.Thresholds
    $checks=New-Object System.Collections.Generic.List[object]

    $checks.Add((New-SitecCheck 'CPU stress' 'PASS' $Benchmark.Stress.Status ($Benchmark.Stress.Status -eq 'PASS')))
    $checks.Add((New-SitecCheck 'Memory verification errors' "<= $($t.MaximumMemoryVerificationErrors)" ([string]$Benchmark.Stress.MemoryVerification.Errors) ([long]$Benchmark.Stress.MemoryVerification.Errors -le [long]$t.MaximumMemoryVerificationErrors)))
    $checks.Add((New-SitecCheck 'WHEA hardware errors' "<= $($t.MaximumWheaEvents)" ([string]$Benchmark.WHEA.Count) ([int]$Benchmark.WHEA.Count -le [int]$t.MaximumWheaEvents)))

    if ($Benchmark.WinSAT.Available) {
        $checks.Add((New-SitecCheck 'WinSAT execution' 'PASS' $Benchmark.WinSAT.Status ($Benchmark.WinSAT.Status -eq 'PASS')))
        if ($null -ne $Benchmark.WinSAT.CpuCompressionMBps) {
            $checks.Add((New-SitecCheck 'CPU compression' ">= $($t.MinimumWinSatCpuCompressionMBps) MB/s" "$($Benchmark.WinSAT.CpuCompressionMBps) MB/s" ([double]$Benchmark.WinSAT.CpuCompressionMBps -ge [double]$t.MinimumWinSatCpuCompressionMBps) 'Warning'))
        }
        if ($null -ne $Benchmark.WinSAT.MemoryMBps) {
            $checks.Add((New-SitecCheck 'Memory bandwidth' ">= $($t.MinimumWinSatMemoryMBps) MB/s" "$($Benchmark.WinSAT.MemoryMBps) MB/s" ([double]$Benchmark.WinSAT.MemoryMBps -ge [double]$t.MinimumWinSatMemoryMBps) 'Warning'))
        }
    } else {
        $checks.Add((New-SitecCheck 'WinSAT availability' 'Available' 'Unavailable' $false 'Warning'))
    }

    if ($Benchmark.DiskSpd.Available) {
        $checks.Add((New-SitecCheck 'DiskSpd execution' 'PASS' $Benchmark.DiskSpd.Status ($Benchmark.DiskSpd.Status -eq 'PASS')))
        if ($null -ne $Benchmark.DiskSpd.SequentialReadMBps) {
            $checks.Add((New-SitecCheck 'SSD sequential read' ">= $($t.MinimumDiskSpdSeqReadMBps) MB/s" "$($Benchmark.DiskSpd.SequentialReadMBps) MB/s" ([double]$Benchmark.DiskSpd.SequentialReadMBps -ge [double]$t.MinimumDiskSpdSeqReadMBps)))
        }
        if ($null -ne $Benchmark.DiskSpd.SequentialWriteMBps) {
            $checks.Add((New-SitecCheck 'SSD sequential write' ">= $($t.MinimumDiskSpdSeqWriteMBps) MB/s" "$($Benchmark.DiskSpd.SequentialWriteMBps) MB/s" ([double]$Benchmark.DiskSpd.SequentialWriteMBps -ge [double]$t.MinimumDiskSpdSeqWriteMBps)))
        }
        if ($null -ne $Benchmark.DiskSpd.RandomReadIOPS) {
            $checks.Add((New-SitecCheck 'SSD 4K random read' ">= $($t.MinimumDiskSpdRandomReadIOPS) IOPS" "$($Benchmark.DiskSpd.RandomReadIOPS) IOPS" ([double]$Benchmark.DiskSpd.RandomReadIOPS -ge [double]$t.MinimumDiskSpdRandomReadIOPS)))
        }
    } else {
        $severity=if ($Benchmark.DiskSpd.PSObject.Properties['Required'] -and $Benchmark.DiskSpd.Required) {'Error'} else {'Warning'}
        $checks.Add((New-SitecCheck 'DiskSpd availability' 'Installed' $Benchmark.DiskSpd.Status $false $severity))
    }

    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{ Status=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'}; Checks=@($checks) }
}
