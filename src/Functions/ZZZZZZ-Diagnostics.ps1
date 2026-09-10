# Structured per-step diagnostics. Loaded after the benchmark engines so wrappers
# can preserve the original implementations while adding durable observability.

$script:SitecOriginalWinSat = ${function:Invoke-SitecWinSat}
$script:SitecOriginalDiskSpd = ${function:Invoke-SitecDiskSpd}

function Initialize-SitecDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    $diag=Join-Path $RunPath 'diagnostics'
    $steps=Join-Path $diag 'steps'
    New-Item -ItemType Directory -Path $steps -Force | Out-Null
    $events=Join-Path $diag 'events.jsonl'
    $human=Join-Path $diag 'process.log'
    if (-not (Test-Path -LiteralPath $events)) { New-Item -ItemType File -Path $events -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $human)) { New-Item -ItemType File -Path $human -Force | Out-Null }
    [pscustomobject]@{Root=$diag;Steps=$steps;Events=$events;Human=$human}
}

function Write-SitecDiagnosticEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Step,
        [ValidateSet('TRACE','INFO','WARNING','ERROR')][string]$Level='INFO',
        [string]$Status='INFO',
        [Parameter(Mandatory)][string]$Message,
        $Data=$null,
        [System.Management.Automation.ErrorRecord]$ErrorRecord=$null
    )
    try {
        $d=Initialize-SitecDiagnostics -RunPath $RunPath
        $o=[ordered]@{
            Timestamp=(Get-Date).ToString('o')
            Stage=$Stage
            Step=$Step
            Level=$Level
            Status=$Status
            Message=$Message
        }
        if ($null -ne $Data) { $o.Data=$Data }
        if ($null -ne $ErrorRecord) {
            $o.Error=[ordered]@{
                Type=$ErrorRecord.Exception.GetType().FullName
                Message=$ErrorRecord.Exception.Message
                Category=[string]$ErrorRecord.CategoryInfo.Category
                FullyQualifiedErrorId=[string]$ErrorRecord.FullyQualifiedErrorId
                ScriptStackTrace=[string]$ErrorRecord.ScriptStackTrace
                Position=[string]$ErrorRecord.InvocationInfo.PositionMessage
            }
        }
        $line=([pscustomobject]$o | ConvertTo-Json -Depth 12 -Compress)
        Add-Content -LiteralPath $d.Events -Value $line -Encoding UTF8
        $humanLine='[{0}] [{1}] [{2}] [{3}] {4}' -f (Get-Date -Format 'HH:mm:ss.fff'),$Level,$Stage,$Step,$Message
        Add-Content -LiteralPath $d.Human -Value $humanLine -Encoding UTF8
    } catch {
        # Diagnostics must never break QC execution.
    }
}

function Write-SitecStepResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath,[Parameter(Mandatory)][string]$Step,[Parameter(Mandatory)]$Value)
    try {
        $d=Initialize-SitecDiagnostics -RunPath $RunPath
        $safe=($Step -replace '[^A-Za-z0-9._-]','_')
        $path=Join-Path $d.Steps ($safe+'.json')
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
        $path
    } catch { $null }
}

function Get-SitecProcessExitMetadata {
    [CmdletBinding()]
    param([AllowNull()]$Process,[string]$Command='',[string]$Arguments='')
    $exit=$null;$pidValue=$null
    try { if ($Process) { $pidValue=$Process.Id } } catch {}
    try { if ($Process -and $Process.HasExited) { $exit=$Process.ExitCode } } catch {}
    [pscustomobject]@{Pid=$pidValue;ExitCode=$exit;Command=$Command;Arguments=$Arguments}
}

function Invoke-SitecWinSat {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    $sw=[Diagnostics.Stopwatch]::StartNew()
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Performance' -Step 'WinSAT' -Status 'START' -Message 'Starting WinSAT CPU and memory qualification.'
    try {
        $r=& $script:SitecOriginalWinSat -Context $Context -RunPath $RunPath
        $sw.Stop()
        Write-SitecStepResult -RunPath $RunPath -Step '20-winsat' -Value $r | Out-Null
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Performance' -Step 'WinSAT' -Status ([string]$r.Status) -Level $(if($r.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("WinSAT completed in {0:N1}s. CPU={1} MB/s, Memory={2} MB/s." -f $sw.Elapsed.TotalSeconds,$r.CpuCompressionMBps,$r.MemoryMBps) -Data $r
        $r
    } catch {
        $sw.Stop()
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Performance' -Step 'WinSAT' -Status 'ERROR' -Level 'ERROR' -Message ("WinSAT threw after {0:N1}s: {1}" -f $sw.Elapsed.TotalSeconds,$_.Exception.Message) -ErrorRecord $_
        throw
    }
}

function Invoke-SitecDiskSpd {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$RunPath)
    $sw=[Diagnostics.Stopwatch]::StartNew()
    Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Performance' -Step 'DiskSpd-Qualification' -Status 'START' -Message 'Starting SSD sequential read/write and 4K random qualification.'
    try {
        $r=& $script:SitecOriginalDiskSpd -Context $Context -RunPath $RunPath
        $sw.Stop()
        Write-SitecStepResult -RunPath $RunPath -Step '30-diskspd-qualification' -Value $r | Out-Null
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Performance' -Step 'DiskSpd-Qualification' -Status ([string]$r.Status) -Level $(if($r.Status -eq 'PASS'){'INFO'}else{'ERROR'}) -Message ("DiskSpd qualification completed in {0:N1}s. Seq R/W={1}/{2} MB/s, 4K read={3} IOPS." -f $sw.Elapsed.TotalSeconds,$r.SequentialReadMBps,$r.SequentialWriteMBps,$r.RandomReadIOPS) -Data $r
        $r
    } catch {
        $sw.Stop()
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Performance' -Step 'DiskSpd-Qualification' -Status 'ERROR' -Level 'ERROR' -Message ("DiskSpd qualification threw after {0:N1}s: {1}" -f $sw.Elapsed.TotalSeconds,$_.Exception.Message) -ErrorRecord $_
        throw
    }
}

function Write-SitecFailureSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath,$BomValidation,$BenchmarkValidation)
    $rows=@()
    foreach ($group in @(
        [pscustomobject]@{Name='BOM';Value=$BomValidation},
        [pscustomobject]@{Name='Benchmark';Value=$BenchmarkValidation}
    )) {
        if ($null -eq $group.Value) { continue }
        foreach ($c in @($group.Value.Checks | Where-Object { $_.Status -ne 'PASS' })) {
            $rows += [pscustomobject]@{
                Group=$group.Name;Name=$c.Name;Status=$c.Status;Severity=$c.Severity;Expected=$c.Expected;Actual=$c.Actual
            }
        }
    }
    $summary=[pscustomobject]@{
        GeneratedAt=(Get-Date).ToString('o')
        FailureCount=@($rows | Where-Object Status -eq 'FAIL').Count
        WarningCount=@($rows | Where-Object Status -eq 'WARNING').Count
        Items=@($rows)
    }
    $path=Join-Path $RunPath 'failure-summary.json'
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    foreach ($r in $rows) {
        Write-SitecDiagnosticEvent -RunPath $RunPath -Stage 'Validation' -Step $r.Name -Level $(if($r.Status -eq 'FAIL'){'ERROR'}else{'WARNING'}) -Status $r.Status -Message ("{0}: expected [{1}], actual [{2}]" -f $r.Name,$r.Expected,$r.Actual) -Data $r
    }
    $summary
}
