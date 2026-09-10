# Loaded after the watchdog. Guarantees cleanup for both normal completion and timeout paths.

$script:SitecBurnInWithWatchdogCore = ${function:Invoke-SitecFullSystemBurnIn}

function Remove-SitecRuntimeTemporaryArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[string]$RunPath='')
    $removed=@()
    try {
        $drive=[string]$Context.Settings.DiskSpd.TargetDrive
        if ([string]::IsNullOrWhiteSpace($drive)) { $drive='C:' }
        $ownedRoot=Join-Path ($drive+'\') 'SitecQC-Temp'
        if (Test-Path -LiteralPath $ownedRoot) {
            Remove-Item -LiteralPath $ownedRoot -Recurse -Force -ErrorAction Stop
            $removed += $ownedRoot
        }
    } catch {
        if ($RunPath) { Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Cleanup' -Step 'BenchmarkTemp' -Status 'WARNING' -Level 'WARNING' -Message ('Unable to remove SitecQC temp directory: '+$_.Exception.Message) }
    }

    # Launcher normally deletes these itself; this catches leftovers after interrupted starts.
    try {
        if ($env:TEMP -and (Test-Path -LiteralPath $env:TEMP)) {
            $cutoff=(Get-Date).AddMinutes(-5)
            foreach($f in @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'SitecQC-*.zip' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt $cutoff)) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop;$removed += $f.FullName } catch {}
            }
            foreach($d in @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'SitecQC-Edge-*' -Directory -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt $cutoff)) {
                try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop;$removed += $d.FullName } catch {}
            }
        }
    } catch {}

    if ($RunPath) {
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Cleanup' -Step 'RuntimeTemp' -Status 'PASS' -Message ("Temporary runtime cleanup completed; removed {0} owned path(s)." -f $removed.Count) -Data ([pscustomobject]@{Removed=@($removed)})
    }
    @($removed)
}

function Invoke-SitecFullSystemBurnIn {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    try {
        & $script:SitecBurnInWithWatchdogCore -Context $Context -RunPath $RunPath
    }
    finally {
        Remove-SitecRuntimeTemporaryArtifacts -Context $Context -RunPath $RunPath | Out-Null
    }
}
