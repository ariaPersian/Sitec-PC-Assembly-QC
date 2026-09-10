# DiskSpd 2.x/2.3 compatible parser. This file loads after ZZ-Compatibility.ps1.
function Get-SitecDiskSpdMetrics {
    [CmdletBinding()]
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

function Get-DiskSpdMetrics {
    param([Parameter(Mandatory)][string]$XmlPath)
    Get-SitecDiskSpdMetrics -XmlPath $XmlPath
}
