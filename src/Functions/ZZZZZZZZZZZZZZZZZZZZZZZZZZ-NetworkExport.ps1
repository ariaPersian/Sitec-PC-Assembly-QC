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

    $requested=@($Files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $missing=@($requested | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($requested.Count -eq 0) {
        return [pscustomobject][ordered]@{Success=$false;Verified=$false;Destination='';Files=@();Hashes=@();Attempts=0;Message='No QC files were supplied for network export.'}
    }
    if ($missing.Count -gt 0) {
        return [pscustomobject][ordered]@{
            Success=$false
            Verified=$false
            Destination=''
            Files=@()
            Hashes=@()
            Attempts=0
            Message=('Required QC export file(s) are missing: '+(@($missing | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', '))
        }
    }

    $RetryCount=[math]::Max(1,[math]::Min(10,$RetryCount))
    $destination=$SharePath.TrimEnd('\')+'\'+$AssetId
    $last=''

    for ($attempt=1;$attempt -le $RetryCount;$attempt++) {
        $partials=@()
        try {
            if (-not (Test-Path -LiteralPath $SharePath)) { throw 'The SMB share is not accessible with the Windows credentials stored on this PC.' }
            New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null

            $hashes=@()
            foreach ($file in $requested) {
                $name=[IO.Path]::GetFileName($file)
                $target=Join-Path $destination $name
                $partial=$target+'.uploading-'+[guid]::NewGuid().ToString('N')
                $partials += $partial

                Copy-Item -LiteralPath $file -Destination $partial -Force -ErrorAction Stop
                $sourceHash=(Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                $remoteHash=(Get-FileHash -LiteralPath $partial -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($sourceHash -ne $remoteHash) {
                    throw "SHA-256 verification failed for $name."
                }

                Move-Item -LiteralPath $partial -Destination $target -Force -ErrorAction Stop
                $partials=@($partials | Where-Object { $_ -ne $partial })
                $finalHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                if ($sourceHash -ne $finalHash) {
                    throw "Final SHA-256 verification failed for $name."
                }

                $hashes += [pscustomobject][ordered]@{
                    File=$name
                    Sha256=$sourceHash
                }
            }

            return [pscustomobject][ordered]@{
                Success=$true
                Verified=$true
                Destination=$destination
                Files=@($requested | ForEach-Object { [IO.Path]::GetFileName($_) })
                Hashes=$hashes
                Attempts=$attempt
                Message=('Transferred and SHA-256 verified {0} QC file(s).' -f $requested.Count)
            }
        } catch {
            $last=$_.Exception.Message
            foreach ($partial in @($partials)) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
    }

    [pscustomobject][ordered]@{
        Success=$false
        Verified=$false
        Destination=$destination
        Files=@($requested | ForEach-Object { [IO.Path]::GetFileName($_) })
        Hashes=@()
        Attempts=$RetryCount
        Message=$last
    }
}

function Remove-SitecLocalMachineReadableOutputAfterTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselineRoot,
        [Parameter(Mandatory)][string]$AssetId
    )

    $certificate=Get-SitecPublishedCertificatePath -BaselineRoot $BaselineRoot -AssetId $AssetId
    $fullJson=Get-SitecPublishedFullJsonPath -BaselineRoot $BaselineRoot -AssetId $AssetId
    $baseline=Get-SitecPublishedBaselinePath -BaselineRoot $BaselineRoot -AssetId $AssetId

    if (-not (Test-Path -LiteralPath $certificate)) {
        return [pscustomobject][ordered]@{
            Success=$false
            KeptCertificate=$false
            Deleted=@()
            Message='Local QC certificate is missing, so machine-readable local evidence was not removed.'
        }
    }

    $deleted=@()
    $errors=@()
    foreach ($path in @($fullJson,$baseline)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            $deleted += [IO.Path]::GetFileName($path)
        } catch {
            $errors += ("{0}: {1}" -f [IO.Path]::GetFileName($path),$_.Exception.Message)
        }
    }

    [pscustomobject][ordered]@{
        Success=($errors.Count -eq 0)
        KeptCertificate=(Test-Path -LiteralPath $certificate)
        Deleted=$deleted
        Message=$(if($errors.Count -eq 0){'Local machine-readable QC output removed; QC certificate retained.'}else{($errors -join '; ')})
    }
}
