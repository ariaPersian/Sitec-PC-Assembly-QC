#requires -version 5.1
[CmdletBinding()]
param([string]$LauncherDir='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path

$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $args="-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    if ($LauncherDir) { $args += " -LauncherDir `"$LauncherDir`"" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args
    exit
}

Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$context=Get-SitecContext
$profile=Get-SitecProfile -Context $context -ProfileId ([string]$context.Settings.DefaultProfileId)
$automaticOperator=[string]$env:USERNAME
$BaselineRoot=Get-SitecBaselineRoot -LauncherDir $LauncherDir
$layout=Initialize-SitecBaselineLayout -BaselineRoot $BaselineRoot

# The production workflow requires SitecQC.exe to run from the local C: drive,
# normally C:\BaselineQC. This prevents the archive flash drive itself from
# appearing in the hardware/storage baseline during the benchmark.
try {
    $driveRoot=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($BaselineRoot))
    $drive=New-Object IO.DriveInfo($driveRoot)
    if ($drive.DriveType -eq [IO.DriveType]::Removable) { throw 'Run SitecQC.exe from C:\BaselineQC, not from a USB/removable drive.' }
} catch [System.Management.Automation.RuntimeException] { throw }
catch {}

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
[xml]$xaml=Get-Content -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
$reader=New-Object System.Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$iconPath=Join-Path $root 'ui\AppIcon.ico'
if (Test-Path -LiteralPath $iconPath) { try { $window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } catch {} }
function C([string]$n){$window.FindName($n)}

$TxtAssetId=C 'TxtAssetId'
$TxtProfileDisplay=C 'TxtProfileDisplay'
$ChkProfileComparison=C 'ChkProfileComparison'
$TxtPsuSerial=C 'TxtPsuSerial'
$TxtCpuAtpo=C 'TxtCpuAtpo'
$TxtSeal1=C 'TxtSeal1'
$ChkBenchCpu=C 'ChkBenchCpu'
$ChkBenchMemory=C 'ChkBenchMemory'
$ChkBenchDisk=C 'ChkBenchDisk'
$ChkBenchGraphics=C 'ChkBenchGraphics'
$BtnDetect=C 'BtnDetect'
$BtnRun=C 'BtnRun'
$BtnCancel=C 'BtnCancel'
$BtnOpenLast=C 'BtnOpenLast'
$TxtHardware=C 'TxtHardware'
$TxtLog=C 'TxtLog'
$TxtStage=C 'TxtStage'
$TxtProgressPercent=C 'TxtProgressPercent'
$TxtElapsed=C 'TxtElapsed'
$TxtRemaining=C 'TxtRemaining'
$TxtMessage=C 'TxtMessage'
$ProgressQc=C 'ProgressQc'
$TxtHeaderStatus=C 'TxtHeaderStatus'
$TxtFooter=C 'TxtFooter'
$ChkNetworkExport=C 'ChkNetworkExport'
$TxtNetworkSharePath=C 'TxtNetworkSharePath'
$BtnOpenNetworkPath=C 'BtnOpenNetworkPath'
$TxtNetworkUsername=C 'TxtNetworkUsername'
$PwdNetworkPassword=C 'PwdNetworkPassword'
$ChkNetworkAutoExport=C 'ChkNetworkAutoExport'
$TxtNetworkRetryCount=C 'TxtNetworkRetryCount'
$BtnTestNetwork=C 'BtnTestNetwork'
$BtnSaveNetwork=C 'BtnSaveNetwork'
$TxtNetworkExportStatus=C 'TxtNetworkExportStatus'

$TxtProfileDisplay.Text=[string]$profile.ProfileId + ' v' + [string]$profile.ProfileVersion
$profileTooltipLines=@(
    ("Profile: {0} v{1}" -f $profile.ProfileId,$profile.ProfileVersion),
    ("Case: {0}" -f $profile.Expected.CaseModel),
    ("Motherboard: {0}" -f $profile.Expected.MotherboardModelContains),
    ("CPU: {0}" -f $profile.Expected.CpuModelContains),
    ("RAM: {0} GB {1}, configured speed >= {2} MHz" -f $profile.Expected.MemoryTotalGB,$profile.Expected.MemoryType,$profile.Expected.MemoryMinimumConfiguredSpeedMHz),
    ("Storage: {0}, >= {1} GB" -f $profile.Expected.StorageModelContains,$profile.Expected.StorageMinimumSizeGB),
    ("GPU: {0}" -f $profile.Expected.GpuModelContains),
    ("PSU: {0}" -f $profile.Expected.PsuModel),
    ("CPU cooler: {0}" -f $profile.Expected.CpuCoolerModel),
    '',
    'This comparison is optional and OFF by default. A mismatch is advisory and does not fail an otherwise healthy PC.'
)
$profileTipText=New-Object Windows.Controls.TextBlock
$profileTipText.Text=($profileTooltipLines -join [Environment]::NewLine)
$profileTipText.TextWrapping='Wrap'
$profileTipText.MaxWidth=560
$ChkProfileComparison.ToolTip=$profileTipText
$profileDisplayTip=New-Object Windows.Controls.TextBlock
$profileDisplayTip.Text=$profileTipText.Text
$profileDisplayTip.TextWrapping='Wrap'
$profileDisplayTip.MaxWidth=560
$TxtProfileDisplay.ToolTip=$profileDisplayTip
$TxtFooter.Text="Local baseline folder: $BaselineRoot  |  After verified network transfer, only the QC Certificate PDF is retained locally."

$script:LastReport=$null
$script:Worker=$null
$script:StartedAt=$null
$script:CurrentStatus=$null
$script:Hardware=$null
$script:WorkRoot=$null
$script:CancelPath=$null
$script:NetworkTestProcess=$null
$script:NetworkTestResultPath=$null
$script:NetworkTestSharePath=''
$script:NetworkTestReason=''
$script:NetworkTestStartedAt=$null
$script:InitialNetworkProbeStarted=$false
$script:NetworkLogLines=@()

$networkSettings=Get-SitecNetworkExportSettings -Context $context -LauncherDir $LauncherDir
$ChkNetworkExport.IsChecked=[bool]$networkSettings.Enabled
$TxtNetworkSharePath.Text=[string]$networkSettings.SharePath
$TxtNetworkUsername.Text=[string]$networkSettings.Username
$PwdNetworkPassword.Password=''
$ChkNetworkAutoExport.IsChecked=[bool]$networkSettings.AutoExport
$TxtNetworkRetryCount.Text=[string]$networkSettings.RetryCount
$TxtNetworkExportStatus.Text='Startup network test pending...'

function Get-SitecCaptureFlag([string]$Name,[bool]$Default) {
    if ($null -eq $profile.Capture) { return $Default }
    $property=$profile.Capture.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    [bool]$property.Value
}

function Ensure-SitecDependencies {
    $needDisk=$false;$needSensors=$false
    if ($context.Settings.DiskSpd.Enabled) {
        $diskPath=Join-Path $root ([string]$context.Settings.DiskSpd.ExeRelativePath)
        $needDisk=-not (Test-Path -LiteralPath $diskPath)
    }
    if ($context.Settings.Sensors.Enabled) {
        $sensorPath=Join-Path $root ([string]$context.Settings.Sensors.LibreHardwareMonitorDllRelativePath)
        $needSensors=-not (Test-Path -LiteralPath $sensorPath)
    }
    if (-not $needDisk -and -not $needSensors) { return }
    $TxtHeaderStatus.Text='PREPARING';$TxtStage.Text='Preparing tools';$TxtMessage.Text='Preparing embedded benchmark/sensor components...'
    $window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)
    $installer=Join-Path $root 'tools\Install-Dependencies.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw 'Dependency payload/installer is missing.' }
    try { & $installer -SkipSensors:(!$needSensors) }
    catch { [Windows.MessageBox]::Show("Some optional/required QC components could not be prepared automatically.`n`n$($_.Exception.Message)",'SITEC QC preparation warning') | Out-Null }
}

function Refresh-SitecHardware {
    try {
        $TxtHeaderStatus.Text='DETECTING';$TxtStage.Text='Hardware discovery';$TxtMessage.Text='Reading SMBIOS, CPU, memory, storage, BIOS, graphics and device status...'
        $window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)
        $h=Get-SitecHardwareInventory
        $script:Hardware=$h
        if ([string]::IsNullOrWhiteSpace($TxtAssetId.Text)) { $TxtAssetId.Text='CASE-' }

        $lines=@()
        $lines += "Computer   : $($h.ComputerName)"
        $lines += "Asset ID   : $($TxtAssetId.Text)"
        $lines += "Board      : $($h.Motherboard.Manufacturer) $($h.Motherboard.Model)"
        $lines += "Board S/N  : $($h.Motherboard.SerialNumber)"
        $lines += "CPU        : $($h.CPU.Model) [$($h.CPU.Cores)C/$($h.CPU.LogicalProcessors)T]"
        $lines += "BIOS       : $($h.BIOS.Version) ($($h.BIOS.ReleaseDate))"
        $lines += "RAM        : $($h.MemoryTotalGB) GB"
        foreach ($memory in @($h.Memory)) { $lines += "  RAM      : $($memory.Slot) | Crucial | S/N $($memory.SerialNumber) | $($memory.ConfiguredSpeedMHz) MHz" }
        foreach ($disk in @($h.Storage)) {
            $text="  STORAGE  : $($disk.Model) | S/N $($disk.SerialNumber) | $($disk.SizeGB) GB | $($disk.BusType)"
            if ($disk.Reliability -and $disk.Reliability.Available) {
                $extra=@();if ($null -ne $disk.Reliability.TemperatureC) { $extra += "Temp $($disk.Reliability.TemperatureC)C" };if ($null -ne $disk.Reliability.PowerOnHours) { $extra += "POH $($disk.Reliability.PowerOnHours)h" };if ($null -ne $disk.Reliability.WearPercent) { $extra += "Wear $($disk.Reliability.WearPercent)%" };if ($extra.Count -gt 0) { $text += ' | ' + ($extra -join ' | ') }
            }
            $lines += $text
        }
        foreach ($gpu in @($h.Graphics)) { $lines += "  GPU      : $($gpu.Name)" }
        if ($h.SystemEnclosure -and (Test-SitecUsefulIdentifier $h.SystemEnclosure.SerialNumber)) { $lines += "Chassis S/N : $($h.SystemEnclosure.SerialNumber)" }
        if ($h.SystemEnclosure -and (Test-SitecUsefulIdentifier $h.SystemEnclosure.SMBIOSAssetTag)) { $lines += "SMBIOS Tag  : $($h.SystemEnclosure.SMBIOSAssetTag)" }
        if (@($h.PnPErrors).Count -gt 0) { $lines += "PnP Errors  : $(@($h.PnPErrors).Count)" }
        $TxtHardware.Text=($lines -join [Environment]::NewLine)
        $TxtHeaderStatus.Text='READY';$TxtStage.Text='Ready'
        $usbCount=@($h.Storage | Where-Object { [string]$_.BusType -match '^(USB|SD|MMC)$' }).Count
        if ($usbCount -gt 0) { $TxtMessage.Text="Disconnect removable storage before running QC. Detected removable storage devices: $usbCount" }
        else { $TxtMessage.Text='Hardware discovery completed. Confirm Asset ID, scan PSU serial and CPU ATPO, then run selected QC. Profile comparison is optional and OFF by default; identity/integrity and benchmark QC remain active.' }
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message,'Hardware detection failed') | Out-Null
        $TxtHeaderStatus.Text='ERROR';$TxtStage.Text='Error';$TxtMessage.Text=$_.Exception.Message
    }
}

function Q([string]$s) { '"' + ($s -replace '"','\"') + '"' }

function Format-SitecUiDuration([double]$Seconds) {
    if ($Seconds -lt 0) { return '--:--' }
    $ts=[TimeSpan]::FromSeconds([math]::Max(0,[math]::Round($Seconds)))
    if ($ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours,$ts.Minutes,$ts.Seconds) }
    return ('{0:00}:{1:00}' -f $ts.Minutes,$ts.Seconds)
}

function Add-SitecUiNetworkLog {
    param([Parameter(Mandatory)][string]$Message)
    $line=('[{0}] [NETWORK] {1}' -f (Get-Date).ToString('HH:mm:ss'),$Message)
    $script:NetworkLogLines += $line

    # Network diagnostics are kept separately in memory so the benchmark
    # worker-log refresh cannot erase the startup/manual connectivity result.
    if ($script:Worker -and -not $script:Worker.HasExited) {
        $workerText=''
        if ($script:CurrentStatus -and $script:CurrentStatus.PSObject.Properties['RunPath']) {
            $workerLog=Join-Path ([string]$script:CurrentStatus.RunPath) 'worker.log'
            if (Test-Path -LiteralPath $workerLog) { $workerText=Get-Content -LiteralPath $workerLog -Raw -Encoding UTF8 }
        }
        $networkText=@($script:NetworkLogLines) -join [Environment]::NewLine
        $TxtLog.Text=if([string]::IsNullOrWhiteSpace($workerText)){$networkText}else{$networkText+[Environment]::NewLine+$workerText}
    } else {
        $TxtLog.Text=(@($script:NetworkLogLines) -join [Environment]::NewLine)
    }
    $TxtLog.ScrollToEnd()
}

function Update-SitecNetworkCredentialFromUi {
    param([switch]$RequirePassword)

    $password=[string]$PwdNetworkPassword.Password
    if ([string]::IsNullOrWhiteSpace($password)) {
        if ($RequirePassword) { throw 'Enter a collector password first.' }
        return $false
    }

    $sharePath=$TxtNetworkSharePath.Text.Trim()
    $username=$TxtNetworkUsername.Text.Trim()
    Set-SitecNetworkExportCredential -SharePath $sharePath -Username $username -Password $password | Out-Null
    $PwdNetworkPassword.Clear()
    Add-SitecUiNetworkLog ("Windows Credential Manager updated for {0} as {1}. Password was not written to SitecQC settings/logs." -f (Get-SitecNetworkExportServer -SharePath $sharePath),$username)
    return $true
}

function Start-SitecNetworkProbe {
    param([ValidateSet('startup','manual')][string]$Reason='manual')

    try {
        if ($script:NetworkTestProcess) {
            try { $script:NetworkTestProcess.Refresh() } catch {}
            if (-not $script:NetworkTestProcess.HasExited) {
                $TxtNetworkExportStatus.Text='Network test is already running in the background.'
                return
            }
        }

        $sharePath=$TxtNetworkSharePath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($sharePath)) { throw 'Collector path is empty.' }

        $networkWorker=Join-Path $root 'tools\Test-NetworkExportWorker.ps1'
        if (-not (Test-Path -LiteralPath $networkWorker)) { throw 'Background network-test worker is missing.' }

        if ($script:NetworkTestResultPath) {
            Remove-Item -LiteralPath $script:NetworkTestResultPath -Force -ErrorAction SilentlyContinue
        }
        $script:NetworkTestResultPath=Join-Path $env:TEMP ('SitecQC-NetworkTest-'+[guid]::NewGuid().ToString('N')+'.json')
        $script:NetworkTestSharePath=$sharePath
        $script:NetworkTestReason=$Reason
        $script:NetworkTestStartedAt=Get-Date

        $args=@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $networkWorker),
            '-SharePath',(Q $sharePath),'-ResultPath',(Q $script:NetworkTestResultPath),'-Reason',(Q $Reason)
        )
        $script:NetworkTestProcess=Start-Process powershell.exe -ArgumentList ($args -join ' ') -PassThru -WindowStyle Hidden
        $BtnTestNetwork.IsEnabled=$false
        $TxtNetworkExportStatus.Text='Testing network in background... You can continue entering QC values.'
        Add-SitecUiNetworkLog ("{0} collector test started for {1}; operator input remains available." -f $Reason,$sharePath)
    } catch {
        $BtnTestNetwork.IsEnabled=$true
        $TxtNetworkExportStatus.Text=('Unable to start network test: '+$_.Exception.Message)
        Add-SitecUiNetworkLog ('Network test could not start: '+$_.Exception.Message)
    }
}
$BtnDetect.Add_Click({ Refresh-SitecHardware })
$TxtAssetId.Add_TextChanged({ $TxtSeal1.Text=$TxtAssetId.Text })
$TxtAssetId.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $TxtPsuSerial.Focus() | Out-Null; $_.Handled=$true } })
$TxtPsuSerial.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $TxtCpuAtpo.Focus() | Out-Null; $_.Handled=$true } })
$TxtCpuAtpo.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $TxtSeal1.Focus() | Out-Null; $_.Handled=$true } })
$TxtSeal1.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $BtnRun.Focus() | Out-Null; $_.Handled=$true } })

$BtnOpenNetworkPath.Add_Click({
    try {
        $path=$TxtNetworkSharePath.Text.Trim()
        $user=$TxtNetworkUsername.Text.Trim()
        [void](Update-SitecNetworkCredentialFromUi)
        $opened=Open-SitecNetworkExportExplorer -SharePath $path -Username $user
        $TxtNetworkExportStatus.Text=("Opened collector: {0}" -f $opened.SharePath)
        Add-SitecUiNetworkLog ("Explorer opened for {0} using the Windows stored SMB credential for {1}." -f $opened.SharePath,$user)
    } catch {
        $TxtNetworkExportStatus.Text=('Open failed: '+$_.Exception.Message)
        Add-SitecUiNetworkLog ('Open collector FAIL: '+$_.Exception.Message)
    }
})

$BtnSaveNetwork.Add_Click({
    try {
        $retry=3
        if (-not [int]::TryParse($TxtNetworkRetryCount.Text,[ref]$retry)) { $retry=3 }
        $credentialUpdated=Update-SitecNetworkCredentialFromUi
        if (-not [string]::IsNullOrWhiteSpace($LauncherDir)) {
            Save-SitecNetworkExportSettings -LauncherDir $LauncherDir -Enabled ([bool]$ChkNetworkExport.IsChecked) -SharePath $TxtNetworkSharePath.Text.Trim() -Username $TxtNetworkUsername.Text.Trim() -AutoExport ([bool]$ChkNetworkAutoExport.IsChecked) -RetryCount $retry -RetryDelaySeconds 2 | Out-Null
            $TxtNetworkExportStatus.Text=if($credentialUpdated){'Network settings and Windows SMB credential saved.'}else{'Network export settings saved; existing Windows SMB password kept.'}
        } else {
            $TxtNetworkExportStatus.Text=if($credentialUpdated){'Windows SMB credential updated. Source-mode settings remain session-only.'}else{'Source mode: settings are active for this session only.'}
        }
    } catch {
        $PwdNetworkPassword.Clear()
        $TxtNetworkExportStatus.Text=('Save failed: '+$_.Exception.Message)
        Add-SitecUiNetworkLog ('Save network settings FAIL: '+$_.Exception.Message)
    }
})

$BtnTestNetwork.Add_Click({
    try {
        [void](Update-SitecNetworkCredentialFromUi)
        Start-SitecNetworkProbe -Reason 'manual'
    } catch {
        $PwdNetworkPassword.Clear()
        $TxtNetworkExportStatus.Text=('Credential update failed: '+$_.Exception.Message)
        Add-SitecUiNetworkLog ('Credential update FAIL: '+$_.Exception.Message)
    }
})

$BtnRun.Add_Click({
    try {
        if ($script:Worker -and -not $script:Worker.HasExited) { return }
        if (-not $script:Hardware) { Refresh-SitecHardware }
        $usbStorage=@($script:Hardware.Storage | Where-Object { [string]$_.BusType -match '^(USB|SD|MMC)$' })
        if ($usbStorage.Count -gt 0) { throw 'Disconnect all USB/removable storage before QC so it is not included in the hardware inventory.' }
        $asset=$TxtAssetId.Text.Trim()
        if ($asset -eq 'CASE-' -or $asset -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$') { throw 'Asset ID is incomplete or invalid. Enter the unique identifier after CASE- (or replace it with a complete valid Asset ID).' }
        $required=@()
        if (Get-SitecCaptureFlag 'RequirePsuSerial' $true) { $required += [pscustomobject]@{Name='PSU serial';Value=$TxtPsuSerial.Text} }
        if (Get-SitecCaptureFlag 'RequireCpuAtpo' $true) { $required += [pscustomobject]@{Name='CPU ATPO';Value=$TxtCpuAtpo.Text} }
        if (Get-SitecCaptureFlag 'RequireSeal1' $true) { $required += [pscustomobject]@{Name='Tamper seal #1';Value=$TxtSeal1.Text} }
        foreach ($item in $required) { if ([string]::IsNullOrWhiteSpace([string]$item.Value)) { throw "$($item.Name) must be scanned or confirmed before final QC." } }

        $benchmarkComponents=@()
        if ($ChkBenchCpu.IsChecked) { $benchmarkComponents += 'CPU' }
        if ($ChkBenchMemory.IsChecked) { $benchmarkComponents += 'Memory' }
        if ($ChkBenchDisk.IsChecked) { $benchmarkComponents += 'Disk' }
        if ($ChkBenchGraphics.IsChecked) { $benchmarkComponents += 'Graphics' }
        if ($benchmarkComponents.Count -eq 0) { throw 'Select at least one hardware component to benchmark.' }
        $benchmarkCsv=$benchmarkComponents -join ','

        $script:WorkRoot=New-SitecWorkingRoot -AssetId $asset -BaseDataRoot ([string]$context.Settings.DataRoot)
        $script:CancelPath=Join-Path $script:WorkRoot 'cancel.request.json'
        Remove-Item -LiteralPath $script:CancelPath -Force -ErrorAction SilentlyContinue
        $worker=Join-Path $root 'Invoke-SitecQC-Compact.ps1'
        $argList=@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $worker),
            '-AssetId',(Q $asset),'-ProfileId',(Q ([string]$profile.ProfileId)),'-Operator',(Q $automaticOperator),
            '-CaseModel',(Q ([string]$profile.Expected.CaseModel)),'-PsuModel',(Q ([string]$profile.Expected.PsuModel)),'-PsuSerial',(Q $TxtPsuSerial.Text.Trim()),
            '-CpuAtpo',(Q $TxtCpuAtpo.Text.Trim()),'-Cooler',(Q ([string]$profile.Expected.CpuCoolerModel)),'-Seal1',(Q $TxtSeal1.Text.Trim()),
            '-BenchmarkComponents',(Q $benchmarkCsv),
            '-BaselineRoot',(Q $BaselineRoot),'-WorkingRoot',(Q $script:WorkRoot),'-ContinueBenchmarkOnBomFailure'
        )
        if($ChkProfileComparison.IsChecked){$argList += '-EnableProfileComparison'}
        $script:StartedAt=Get-Date;$script:CurrentStatus=$null;$script:LastReport=$null
        $script:Worker=Start-Process powershell.exe -ArgumentList ($argList -join ' ') -PassThru -WindowStyle Hidden
        $BtnRun.IsEnabled=$false;$BtnDetect.IsEnabled=$false;$BtnOpenLast.IsEnabled=$false
        $BtnCancel.Visibility='Visible';$BtnCancel.IsEnabled=$true
        @($ChkProfileComparison,$ChkBenchCpu,$ChkBenchMemory,$ChkBenchDisk,$ChkBenchGraphics) | ForEach-Object { $_.IsEnabled=$false }
        $profileMode=if($ChkProfileComparison.IsChecked){"ON ($($profile.ProfileId))"}else{'OFF'}
        $TxtHeaderStatus.Text='RUNNING';$TxtLog.Text=(@($script:NetworkLogLines) -join [Environment]::NewLine);$ProgressQc.Value=1;$TxtProgressPercent.Text='1%';$TxtElapsed.Text='Elapsed: 00:00';$TxtRemaining.Text='Remaining: --:--';$TxtStage.Text='Starting';$TxtMessage.Text=("QC worker launched for [{0}]. Profile comparison: {1}. Scratch data: {2} | Final output: {3}\Output" -f $benchmarkCsv,$profileMode,$script:WorkRoot,$BaselineRoot)
    } catch { [Windows.MessageBox]::Show($_.Exception.Message,'Cannot start QC') | Out-Null }
})

$BtnCancel.Add_Click({
    if (-not $script:Worker -or $script:Worker.HasExited -or [string]::IsNullOrWhiteSpace($script:CancelPath)) { return }
    $answer=[Windows.MessageBox]::Show('Cancel the active benchmark? Partial evidence and the Full JSON record will still be finalized and saved.','Cancel benchmark',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
    if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    try {
        [ordered]@{
            Schema='SITEC-QC-CANCEL-V1'
            AssetId=$TxtAssetId.Text.Trim()
            RequestedAt=(Get-Date).ToString('o')
            RequestedBy=$automaticOperator
            Reason='Operator requested benchmark cancellation from the SitecQC GUI.'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CancelPath -Encoding UTF8
        $BtnCancel.IsEnabled=$false
        $TxtHeaderStatus.Text='CANCELLING'
        $TxtHeaderStatus.Foreground='#FFD166'
        $TxtStage.Text='Cancelling benchmark'
        $TxtMessage.Text='Cancellation requested. Active benchmark processes are being stopped safely; partial evidence and Full JSON will be finalized.'
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message,'Unable to cancel benchmark') | Out-Null
    }
})

$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if (-not $script:Worker) { return }
    $asset=$TxtAssetId.Text.Trim()
    if ($script:WorkRoot) {
        $assetRoot=Join-Path $script:WorkRoot ("Assets\$asset\Runs")
        if (Test-Path $assetRoot) {
            $statusFile=Get-ChildItem -LiteralPath $assetRoot -Filter status.json -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $script:StartedAt.AddSeconds(-2) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($statusFile) {
                try {
                    $s=Get-Content $statusFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $script:CurrentStatus=$s
                    $pct=[int][math]::Max(0,[math]::Min(100,[int]$s.Percent))
                    $ProgressQc.Value=$pct
                    $TxtProgressPercent.Text=("$pct%")
                    $TxtStage.Text=[string]$s.Stage
                    $TxtMessage.Text=[string]$s.Message
                    $elapsedSeconds=if($s.PSObject.Properties['ElapsedSeconds']){[double]$s.ElapsedSeconds}elseif($script:StartedAt){((Get-Date)-$script:StartedAt).TotalSeconds}else{0}
                    $TxtElapsed.Text=('Elapsed: '+(Format-SitecUiDuration $elapsedSeconds))
                    if($s.PSObject.Properties['RemainingSeconds'] -and $null -ne $s.RemainingSeconds -and [double]$s.RemainingSeconds -ge 0){
                        $TxtRemaining.Text=('Remaining: '+(Format-SitecUiDuration ([double]$s.RemainingSeconds)))
                    } else {
                        $TxtRemaining.Text='Remaining: calculating...'
                    }
                    $log=Join-Path $s.RunPath 'worker.log'
                    if (Test-Path $log) {
                        $workerText=Get-Content $log -Raw -Encoding UTF8
                        $networkText=@($script:NetworkLogLines) -join [Environment]::NewLine
                        $TxtLog.Text=if([string]::IsNullOrWhiteSpace($networkText)){$workerText}else{$networkText+[Environment]::NewLine+$workerText}
                        $TxtLog.ScrollToEnd()
                    }
                } catch {}
            }
        }
    }
    if ($script:Worker.HasExited) {
        $BtnRun.IsEnabled=$true;$BtnDetect.IsEnabled=$true
        $BtnCancel.IsEnabled=$false;$BtnCancel.Visibility='Collapsed'
        @($ChkProfileComparison,$ChkBenchCpu,$ChkBenchMemory,$ChkBenchDisk,$ChkBenchGraphics) | ForEach-Object { $_.IsEnabled=$true }
        $published=Get-SitecPublishedCertificatePath -BaselineRoot $BaselineRoot -AssetId $asset
        if (Test-Path -LiteralPath $published) { $script:LastReport=$published }
        $BtnOpenLast.IsEnabled=[bool]$script:LastReport
        $ProgressQc.Value=100;$TxtProgressPercent.Text='100%'
        if($script:StartedAt){$TxtElapsed.Text=('Elapsed: '+(Format-SitecUiDuration (((Get-Date)-$script:StartedAt).TotalSeconds)))}
        $TxtRemaining.Text='Remaining: 00:00'
        # The freshly published Full JSON is authoritative for the completed
        # QC classification. This prevents an exit-code propagation problem in
        # the launcher/wrapper from relabeling a completed QC FAIL as a runtime
        # ERROR in the GUI.
        $publishedStatus='';$profileComparisonEnabled=$false;$profileConformance='SKIPPED';$profileWarnings=@();$reason=''
        $fullJson=Get-SitecPublishedFullJsonPath -BaselineRoot $BaselineRoot -AssetId $asset
        $fullIsCurrent=$false
        if(Test-Path -LiteralPath $fullJson){
            try {
                $fullItem=Get-Item -LiteralPath $fullJson -ErrorAction Stop
                $fullIsCurrent=(-not $script:StartedAt -or $fullItem.LastWriteTime -ge $script:StartedAt.AddSeconds(-5))
                if($fullIsCurrent){
                    $full=Get-Content -LiteralPath $fullJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    if($full.PSObject.Properties['OverallStatus']){$publishedStatus=[string]$full.OverallStatus}
                    if($full.PSObject.Properties['ProfileComparisonEnabled']){$profileComparisonEnabled=[bool]$full.ProfileComparisonEnabled}
                    if($full.PSObject.Properties['ProfileConformanceStatus']){$profileConformance=[string]$full.ProfileConformanceStatus}
                    elseif($full.PSObject.Properties['BomConformanceStatus']){$profileConformance=[string]$full.BomConformanceStatus}
                    if($full.PSObject.Properties['ProfileComparison'] -and $full.ProfileComparison -and $full.ProfileComparison.PSObject.Properties['Checks']){
                        $profileWarnings=@($full.ProfileComparison.Checks | Where-Object Status -eq 'WARNING' | Select-Object -ExpandProperty Name)
                    } elseif($full.BomValidation -and $full.BomValidation.PSObject.Properties['Checks']){
                        $profileWarnings=@($full.BomValidation.Checks | Where-Object Status -eq 'WARNING' | Select-Object -ExpandProperty Name)
                    }
                    if($full.PSObject.Properties['ErrorSummary'] -and $full.ErrorSummary){$reason=[string]$full.ErrorSummary.PrimaryMessage}
                }
            } catch {}
        }

        $effectiveStatus=''
        if($fullIsCurrent -and -not [string]::IsNullOrWhiteSpace($publishedStatus)){$effectiveStatus=$publishedStatus}
        elseif($script:Worker.ExitCode -eq 0){$effectiveStatus='PASS'}
        elseif($script:Worker.ExitCode -eq 2){$effectiveStatus='FAIL'}
        else{$effectiveStatus='ERROR'}

        if ($effectiveStatus -in @('PASS','PASS_WITH_BOM_MISMATCH')) {
            $TxtHeaderStatus.Text='PASS';$TxtHeaderStatus.Foreground='#A8E6BE'
            if($profileConformance -eq 'MISMATCH'){
                $TxtStage.Text='Complete - profile mismatch advisory'
                $summary=($profileWarnings | Select-Object -First 4) -join '; '
                if([string]::IsNullOrWhiteSpace($summary)){$summary='Detected hardware differs from the selected production profile.'}
                $TxtMessage.Text=("Hardware QC PASS. Optional profile comparison: MISMATCH (advisory): {0} This does not fail the PC. QC Certificate PDF + Full JSON saved to {1}\Output." -f $summary,$BaselineRoot)
            } elseif(-not $profileComparisonEnabled -or $profileConformance -eq 'SKIPPED'){
                $TxtStage.Text='Complete - profile comparison skipped'
                $TxtMessage.Text="QC complete: PASS. Hardware identity/integrity and selected benchmarks passed. Optional profile comparison was not selected. QC Certificate PDF + Full JSON saved to $BaselineRoot\Output."
            } else {
                $TxtStage.Text='Complete - profile match'
                $TxtMessage.Text="QC complete: PASS. Identity/integrity PASS, profile comparison MATCH, and selected benchmark QC PASS. QC Certificate PDF + Full JSON saved to $BaselineRoot\Output."
            }
        }
        elseif ($effectiveStatus -in @('FAIL','CANCELLED')) {
            if($effectiveStatus -eq 'CANCELLED'){
                $TxtHeaderStatus.Text='CANCELLED';$TxtHeaderStatus.Foreground='#FFD166';$TxtStage.Text='Benchmark cancelled'
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason='Benchmark cancelled by operator.' }
                $TxtMessage.Text=("QC benchmark cancelled. {0} Partial PDF/Full JSON evidence was saved to {1}\Output." -f $reason,$BaselineRoot)
            } else {
                $TxtHeaderStatus.Text='FAIL';$TxtHeaderStatus.Foreground='#FFB4AB';$TxtStage.Text='Complete - QC FAIL'
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason='One or more QC validation gates failed.' }
                $TxtMessage.Text=("QC completed: FAIL. {0} QC Certificate PDF + Full JSON were saved to {1}\Output. Exact failure details are in Full JSON; this is a QC result, not an application runtime error." -f $reason,$BaselineRoot)
            }
        }
        else {
            $TxtHeaderStatus.Text='ERROR';$TxtHeaderStatus.Foreground='#FFB4AB';$TxtStage.Text='Application runtime error'
            $failureMessage=$reason
            $failureJson=Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ($asset+'-LastFailure.json')
            if ([string]::IsNullOrWhiteSpace($failureMessage) -and (Test-Path -LiteralPath $failureJson)) {
                try { $failureMessage=[string](Get-Content -LiteralPath $failureJson -Raw -Encoding UTF8 | ConvertFrom-Json).message } catch {}
            }
            if ([string]::IsNullOrWhiteSpace($failureMessage)) { $failureMessage='The QC application or publishing pipeline encountered a runtime error.' }
            $TxtMessage.Text=("QC application ERROR. {0} Full JSON is the authoritative QC evidence when it is available." -f $failureMessage)
        }
        try {
            if ([bool]$ChkNetworkExport.IsChecked -and [bool]$ChkNetworkAutoExport.IsChecked) {
                $retry=3
                if (-not [int]::TryParse($TxtNetworkRetryCount.Text,[ref]$retry)) { $retry=3 }
                $certificate=Get-SitecPublishedCertificatePath -BaselineRoot $BaselineRoot -AssetId $asset
                $export=Invoke-SitecNetworkExport -AssetId $asset -SharePath $TxtNetworkSharePath.Text.Trim() -Files @($fullJson,$certificate) -RetryCount $retry -RetryDelaySeconds 2
                if ($export.Success -and $export.Verified) {
                    $retention=Remove-SitecLocalMachineReadableOutputAfterTransfer -BaselineRoot $BaselineRoot -AssetId $asset
                    if ($retention.Success) {
                        $TxtNetworkExportStatus.Text=("Transfer complete and verified: {0}" -f $export.Destination)
                        $TxtMessage.Text += (" Network transfer: SUCCESS -> {0}. Full JSON + QC Certificate were SHA-256 verified on the collector. Local retention: QC Certificate PDF only." -f $export.Destination)
                    } else {
                        $TxtNetworkExportStatus.Text=("Transfer verified; local cleanup warning: {0}" -f $retention.Message)
                        $TxtMessage.Text += (" Network transfer succeeded, but local cleanup was incomplete: {0}" -f $retention.Message)
                    }
                } else {
                    $TxtNetworkExportStatus.Text=("Transfer failed: {0}" -f $export.Message)
                    $TxtMessage.Text += ' Network transfer failed; local QC Certificate and machine-readable JSON evidence were preserved to prevent data loss.'
                }
            }
        } catch {
            $TxtNetworkExportStatus.Text=('Export failed: '+$_.Exception.Message)
            $TxtMessage.Text += ' Network export failed; local PDF and Full JSON were preserved.'
        }
        $script:Worker=$null;$script:WorkRoot=$null;$script:CancelPath=$null
    }
})
$timer.Start()

$networkTimer=New-Object Windows.Threading.DispatcherTimer
$networkTimer.Interval=[TimeSpan]::FromMilliseconds(400)
$networkTimer.Add_Tick({
    if (-not $script:NetworkTestProcess) { return }

    try { $script:NetworkTestProcess.Refresh() } catch {}
    if (-not $script:NetworkTestProcess.HasExited) { return }

    $result=$null
    try {
        if ($script:NetworkTestResultPath -and (Test-Path -LiteralPath $script:NetworkTestResultPath)) {
            $result=Get-Content -LiteralPath $script:NetworkTestResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    } catch {
        $result=$null
    }

    if ($result -and [bool]$result.Success) {
        $TxtNetworkExportStatus.Text=("Connected: background {0} test passed for {1}." -f $script:NetworkTestReason,$script:NetworkTestSharePath)
        Add-SitecUiNetworkLog ("{0} collector test PASS: {1}" -f $script:NetworkTestReason,[string]$result.Message)
    } else {
        $message=if($result -and -not [string]::IsNullOrWhiteSpace([string]$result.Message)){[string]$result.Message}else{'Background network-test worker ended without a readable result.'}
        $TxtNetworkExportStatus.Text=("Connection test failed: {0}" -f $message)
        Add-SitecUiNetworkLog ("{0} collector test FAIL: {1}" -f $script:NetworkTestReason,$message)
    }

    if ($script:NetworkTestResultPath) {
        Remove-Item -LiteralPath $script:NetworkTestResultPath -Force -ErrorAction SilentlyContinue
    }
    try { $script:NetworkTestProcess.Dispose() } catch {}
    $script:NetworkTestProcess=$null
    $script:NetworkTestResultPath=$null
    $BtnTestNetwork.IsEnabled=$true
})
$networkTimer.Start()

$window.Add_ContentRendered({
    if ($script:InitialNetworkProbeStarted) { return }
    $script:InitialNetworkProbeStarted=$true
    if ([bool]$ChkNetworkExport.IsChecked) {
        Start-SitecNetworkProbe -Reason 'startup'
    } else {
        $TxtNetworkExportStatus.Text='Startup network test skipped because network export is disabled.'
        Add-SitecUiNetworkLog 'Startup collector test skipped because network export is disabled.'
    }
})

$window.Add_Closed({
    try { $networkTimer.Stop() } catch {}
    if ($script:NetworkTestProcess) {
        try {
            $script:NetworkTestProcess.Refresh()
            if (-not $script:NetworkTestProcess.HasExited) { Stop-Process -Id $script:NetworkTestProcess.Id -Force -ErrorAction SilentlyContinue }
            $script:NetworkTestProcess.Dispose()
        } catch {}
    }
    if ($script:NetworkTestResultPath) { Remove-Item -LiteralPath $script:NetworkTestResultPath -Force -ErrorAction SilentlyContinue }
})

$BtnOpenLast.Add_Click({ if ($script:LastReport -and (Test-Path $script:LastReport)) { Start-Process $script:LastReport } })

try { Ensure-SitecDependencies } catch {}
Refresh-SitecHardware
if ([string]::IsNullOrWhiteSpace($TxtAssetId.Text)) { $TxtAssetId.Text='CASE-' }
$TxtAssetId.Focus() | Out-Null
$TxtAssetId.CaretIndex=$TxtAssetId.Text.Length
[void]$window.ShowDialog()
