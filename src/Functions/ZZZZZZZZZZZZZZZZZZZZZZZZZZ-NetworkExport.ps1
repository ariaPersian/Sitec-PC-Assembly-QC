function Get-SitecNetworkExportSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$LauncherDir=''
    )

    $defaults=$null
    if ($Context.Settings -and $Context.Settings.PSObject.Properties['NetworkExport']) {
        $defaults=$Context.Settings.NetworkExport
    }

    $enabled=$true
    $sharePath='\\10.50.50.20\QC-Results'
    $username='QCTransfer'
    $autoExport=$true
    $retryCount=3
    $retryDelaySeconds=2

    if ($defaults) {
        if ($defaults.PSObject.Properties['Enabled']) { $enabled=[bool]$defaults.Enabled }
        if ($defaults.PSObject.Properties['SharePath'] -and -not [string]::IsNullOrWhiteSpace([string]$defaults.SharePath)) { $sharePath=[string]$defaults.SharePath }
        if ($defaults.PSObject.Properties['Username'] -and -not [string]::IsNullOrWhiteSpace([string]$defaults.Username)) { $username=[string]$defaults.Username }
        if ($defaults.PSObject.Properties['AutoExport']) { $autoExport=[bool]$defaults.AutoExport }
        if ($defaults.PSObject.Properties['RetryCount']) { $retryCount=[int]$defaults.RetryCount }
        if ($defaults.PSObject.Properties['RetryDelaySeconds']) { $retryDelaySeconds=[int]$defaults.RetryDelaySeconds }
    }

    $localPath=''
    if (-not [string]::IsNullOrWhiteSpace($LauncherDir)) {
        $localPath=Join-Path $LauncherDir 'SitecQC.local.json'
        if (Test-Path -LiteralPath $localPath) {
            try {
                $doc=Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($doc.PSObject.Properties['NetworkExport']) {
                    $local=$doc.NetworkExport
                    if ($local.PSObject.Properties['Enabled']) { $enabled=[bool]$local.Enabled }
                    if ($local.PSObject.Properties['SharePath'] -and -not [string]::IsNullOrWhiteSpace([string]$local.SharePath)) { $sharePath=[string]$local.SharePath }
                    if ($local.PSObject.Properties['Username'] -and -not [string]::IsNullOrWhiteSpace([string]$local.Username)) { $username=[string]$local.Username }
                    if ($local.PSObject.Properties['AutoExport']) { $autoExport=[bool]$local.AutoExport }
                    if ($local.PSObject.Properties['RetryCount']) { $retryCount=[int]$local.RetryCount }
                    if ($local.PSObject.Properties['RetryDelaySeconds']) { $retryDelaySeconds=[int]$local.RetryDelaySeconds }
                }
            } catch {}
        }
    }

    if ($retryCount -lt 1) { $retryCount=1 }
    if ($retryCount -gt 10) { $retryCount=10 }
    if ($retryDelaySeconds -lt 0) { $retryDelaySeconds=0 }
    if ($retryDelaySeconds -gt 30) { $retryDelaySeconds=30 }

    [pscustomobject][ordered]@{
        Enabled=$enabled
        SharePath=$sharePath
        Username=$username
        AutoExport=$autoExport
        RetryCount=$retryCount
        RetryDelaySeconds=$retryDelaySeconds
        LocalSettingsPath=$localPath
    }
}

function Save-SitecNetworkExportSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherDir,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][bool]$AutoExport,
        [int]$RetryCount=3,
        [int]$RetryDelaySeconds=2
    )

    if ([string]::IsNullOrWhiteSpace($LauncherDir)) { throw 'The launcher folder is not available; network export settings cannot be saved.' }
    if ([string]::IsNullOrWhiteSpace($SharePath) -or $SharePath -notmatch '^\\\\[^\\]+\\[^\\]+') { throw 'Network share must be a UNC path such as \\server\share.' }
    if ([string]::IsNullOrWhiteSpace($Username)) { throw 'Network export username is required.' }

    $RetryCount=[math]::Max(1,[math]::Min(10,$RetryCount))
    $RetryDelaySeconds=[math]::Max(0,[math]::Min(30,$RetryDelaySeconds))

    $path=Join-Path $LauncherDir 'SitecQC.local.json'
    [ordered]@{
        NetworkExport=[ordered]@{
            Enabled=$Enabled
            SharePath=$SharePath.Trim()
            Username=$Username.Trim()
            AutoExport=$AutoExport
            RetryCount=$RetryCount
            RetryDelaySeconds=$RetryDelaySeconds
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Get-SitecNetworkExportServer {
    param([Parameter(Mandatory)][string]$SharePath)
    if ($SharePath -match '^\\\\([^\\]+)\\') { return $matches[1] }
    ''
}

function Test-SitecNetworkExportConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SharePath)

    try {
        $server=Get-SitecNetworkExportServer -SharePath $SharePath
        if ([string]::IsNullOrWhiteSpace($server)) { throw 'Network share path is not a valid UNC path.' }

        $tcp=New-Object Net.Sockets.TcpClient
        try {
            $ar=$tcp.BeginConnect($server,445,$null,$null)
            if (-not $ar.AsyncWaitHandle.WaitOne(2000,$false)) { throw "TCP/445 is not reachable on $server." }
            $tcp.EndConnect($ar)
        } finally { $tcp.Dispose() }

        if (-not (Test-Path -LiteralPath $SharePath)) {
            throw 'The SMB share is not accessible with the Windows credentials stored on this PC.'
        }

        $testPath=Join-Path $SharePath ('.__sitec_qc_write_test_'+[guid]::NewGuid().ToString('N')+'.tmp')
        'SITEC-QC-NETWORK-WRITE-TEST' | Set-Content -LiteralPath $testPath -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $testPath -Force -ErrorAction Stop

        [pscustomobject][ordered]@{Success=$true;Message='TCP/445, SMB access, and write/delete test succeeded.';SharePath=$SharePath}
    } catch {
        [pscustomobject][ordered]@{Success=$false;Message=$_.Exception.Message;SharePath=$SharePath}
    }
}

function Invoke-SitecNetworkExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$SharePath,
        [Parameter(Mandatory)][string[]]$Files,
        [int]$RetryCount=3,
        [int]$RetryDelaySeconds=2
    )

    $existing=@($Files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    if ($existing.Count -eq 0) {
        return [pscustomobject][ordered]@{Success=$false;Destination='';Files=@();Attempts=0;Message='No published QC files were available for network export.'}
    }

    $RetryCount=[math]::Max(1,[math]::Min(10,$RetryCount))
    $destination=$SharePath.TrimEnd('\')+'\'+$AssetId
    $last=''

    for ($attempt=1;$attempt -le $RetryCount;$attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $SharePath)) { throw 'The SMB share is not accessible with the Windows credentials stored on this PC.' }
            New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
            foreach ($file in $existing) {
                Copy-Item -LiteralPath $file -Destination (Join-Path $destination ([IO.Path]::GetFileName($file)) -ErrorAction Stop)
            }

            return [pscustomobject][ordered]@{
                Success=$true
                Destination=$destination
                Files=@($existing | ForEach-Object { [IO.Path]::GetFileName($_) })
                Attempts=$attempt
                Message=('Exported {0} QC file(s).' -f $existing.Count)
            }
        } catch {
            $last=$_.Exception.Message
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }

    [pscustomobject][ordered]@{
        Success=$false
        Destination=$destination
        Files=@($existing | ForEach-Object { [IO.Path]::GetFileName($_) })
        Attempts=$RetryCount
        Message=$last
    }
}
