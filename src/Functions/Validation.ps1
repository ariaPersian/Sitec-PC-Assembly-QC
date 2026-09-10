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

    # Plain PowerShell arrays are intentional here. Windows PowerShell 5.1 can
    # throw "Argument types do not match" while enumerating some generic
    # List[object] instances into PSCustomObject properties.
    $e=$Profile.Expected
    $checks=@()

    $checks += New-SitecCheck 'Case model' ([string]$e.CaseModel) ([string]$Physical.CaseModel) ([string]$Physical.CaseModel -eq [string]$e.CaseModel)
    $checks += New-SitecCheck 'PSU model' ([string]$e.PsuModel) ([string]$Physical.PsuModel) ([string]$Physical.PsuModel -eq [string]$e.PsuModel)
    $checks += New-SitecCheck 'Motherboard model' ([string]$e.MotherboardModelContains) ([string]$Hardware.Motherboard.Model) ([string]$Hardware.Motherboard.Model -like ('*' + [string]$e.MotherboardModelContains + '*'))
    $checks += New-SitecCheck 'CPU model' ([string]$e.CpuModelContains) ([string]$Hardware.CPU.Model) ([string]$Hardware.CPU.Model -like ('*' + [string]$e.CpuModelContains + '*'))
    $checks += New-SitecCheck 'RAM total' ("$($e.MemoryTotalGB) GB") ("$($Hardware.MemoryTotalGB) GB") ([double]$Hardware.MemoryTotalGB -eq [double]$e.MemoryTotalGB)

    $ramTypes=@($Hardware.Memory | Select-Object -ExpandProperty Type -Unique)
    $checks += New-SitecCheck 'RAM type' ([string]$e.MemoryType) ($ramTypes -join ', ') ($ramTypes -contains [string]$e.MemoryType)

    $speedMeasurement=$Hardware.Memory | Measure-Object ConfiguredSpeedMHz -Minimum
    $minSpeed=if ($null -ne $speedMeasurement.Minimum) {[int]$speedMeasurement.Minimum} else {0}
    $checks += New-SitecCheck 'RAM configured speed' (">= $($e.MemoryMinimumConfiguredSpeedMHz) MHz") ("$minSpeed MHz") ($minSpeed -ge [int]$e.MemoryMinimumConfiguredSpeedMHz)

    $storage=@($Hardware.Storage | Where-Object {
        $_.Model -like ('*' + [string]$e.StorageModelContains + '*') -or
        $_.FriendlyName -like ('*' + [string]$e.StorageModelContains + '*')
    })
    $checks += New-SitecCheck 'Storage model' ([string]$e.StorageModelContains) (($Hardware.Storage | Select-Object -ExpandProperty Model) -join '; ') ($storage.Count -gt 0)
    $storageMeasurement=$Hardware.Storage | Measure-Object SizeGB -Maximum
    $largest=if ($null -ne $storageMeasurement.Maximum) {[double]$storageMeasurement.Maximum} else {0}
    $checks += New-SitecCheck 'Storage capacity' (">= $($e.StorageMinimumSizeGB) GB") ("$largest GB") ($largest -ge [double]$e.StorageMinimumSizeGB)

    if (-not [string]::IsNullOrWhiteSpace([string]$e.GpuModelContains)) {
        $gpuMatch=@($Hardware.Graphics | Where-Object { $_.Name -like ('*' + [string]$e.GpuModelContains + '*') })
        $checks += New-SitecCheck 'Graphics' ([string]$e.GpuModelContains) (($Hardware.Graphics | Select-Object -ExpandProperty Name) -join '; ') ($gpuMatch.Count -gt 0) 'Warning'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$e.CpuCoolerModel)) {
        $checks += New-SitecCheck 'CPU cooler' ([string]$e.CpuCoolerModel) ([string]$Physical.Cooler) ([string]$Physical.Cooler -eq [string]$e.CpuCoolerModel)
    }

    # Capture requirements are profile-controlled. If Capture is absent, keep
    # the original conservative behavior for backward compatibility.
    $capture=$Profile.Capture
    $requirePsuSerial=if ($null -eq $capture) {$true} else {[bool]$capture.RequirePsuSerial}
    $requireCpuAtpo=if ($null -eq $capture) {$true} else {[bool]$capture.RequireCpuAtpo}
    $requireSeal1=if ($null -eq $capture) {$true} else {[bool]$capture.RequireSeal1}
    $requireSeal2=if ($null -eq $capture) {$false} else {[bool]$capture.RequireSeal2}

    $required=@(
        [pscustomobject]@{Name='Motherboard serial';Value=$Hardware.Motherboard.SerialNumber;Required=$true},
        [pscustomobject]@{Name='RAM serial';Value=(($Hardware.Memory | Select-Object -ExpandProperty SerialNumber) -join ',');Required=$true},
        [pscustomobject]@{Name='SSD serial';Value=(($Hardware.Storage | Select-Object -ExpandProperty SerialNumber) -join ',');Required=$true},
        [pscustomobject]@{Name='CPU ATPO';Value=$Physical.CpuAtpo;Required=$requireCpuAtpo},
        [pscustomobject]@{Name='PSU serial';Value=$Physical.PsuSerial;Required=$requirePsuSerial},
        [pscustomobject]@{Name='Seal #1';Value=$Physical.Seal1;Required=$requireSeal1},
        [pscustomobject]@{Name='Seal #2';Value=$Physical.Seal2;Required=$requireSeal2}
    )
    foreach ($item in $required) {
        if (-not $item.Required) { continue }
        $actual=[string]$item.Value
        $ok=-not [string]::IsNullOrWhiteSpace($actual)
        $checks += New-SitecCheck ([string]$item.Name) 'Present' $actual $ok
    }

    if (@($Hardware.PnPErrors).Count -gt 0) {
        $checks += New-SitecCheck 'PnP device errors' '0' ([string]@($Hardware.PnPErrors).Count) $false
    }

    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{Status=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'};Checks=$checks}
}

function Test-SitecBenchmarkResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Benchmark,[Parameter(Mandatory)]$Profile)
    $t=$Profile.Thresholds
    $checks=@()

    $checks += New-SitecCheck 'CPU stress' 'PASS' ([string]$Benchmark.Stress.Status) ([string]$Benchmark.Stress.Status -eq 'PASS')
    $checks += New-SitecCheck 'Memory verification errors' ("<= $($t.MaximumMemoryVerificationErrors)") ([string]$Benchmark.Stress.MemoryVerification.Errors) ([long]$Benchmark.Stress.MemoryVerification.Errors -le [long]$t.MaximumMemoryVerificationErrors)
    $checks += New-SitecCheck 'WHEA hardware errors' ("<= $($t.MaximumWheaEvents)") ([string]$Benchmark.WHEA.Count) ([int]$Benchmark.WHEA.Count -le [int]$t.MaximumWheaEvents)

    if ($Benchmark.WinSAT.Available) {
        $checks += New-SitecCheck 'WinSAT execution' 'PASS' ([string]$Benchmark.WinSAT.Status) ([string]$Benchmark.WinSAT.Status -eq 'PASS')
        if ($null -ne $Benchmark.WinSAT.CpuCompressionMBps) {
            $checks += New-SitecCheck 'CPU compression' (">= $($t.MinimumWinSatCpuCompressionMBps) MB/s") ("$($Benchmark.WinSAT.CpuCompressionMBps) MB/s") ([double]$Benchmark.WinSAT.CpuCompressionMBps -ge [double]$t.MinimumWinSatCpuCompressionMBps) 'Warning'
        }
        if ($null -ne $Benchmark.WinSAT.MemoryMBps) {
            $checks += New-SitecCheck 'Memory bandwidth' (">= $($t.MinimumWinSatMemoryMBps) MB/s") ("$($Benchmark.WinSAT.MemoryMBps) MB/s") ([double]$Benchmark.WinSAT.MemoryMBps -ge [double]$t.MinimumWinSatMemoryMBps) 'Warning'
        }
    } else {
        $checks += New-SitecCheck 'WinSAT availability' 'Available' 'Unavailable' $false 'Warning'
    }

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
        $severity=if ($Benchmark.DiskSpd.PSObject.Properties['Required'] -and $Benchmark.DiskSpd.Required) {'Error'} else {'Warning'}
        $checks += New-SitecCheck 'DiskSpd availability' 'Installed' ([string]$Benchmark.DiskSpd.Status) $false $severity
    }

    $failed=@($checks | Where-Object { -not $_.Passed -and $_.Severity -ne 'Warning' })
    [pscustomobject]@{Status=if ($failed.Count -eq 0) {'PASS'} else {'FAIL'};Checks=$checks}
}
