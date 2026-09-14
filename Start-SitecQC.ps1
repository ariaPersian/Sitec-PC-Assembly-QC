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
$TxtExpectedSummary=C 'TxtExpectedSummary'
$TxtPsuSerial=C 'TxtPsuSerial'
$TxtCpuAtpo=C 'TxtCpuAtpo'
$TxtSeal1=C 'TxtSeal1'
$BtnDetect=C 'BtnDetect'
$BtnRun=C 'BtnRun'
$BtnOpenLast=C 'BtnOpenLast'
$TxtHardware=C 'TxtHardware'
$TxtLog=C 'TxtLog'
$TxtStage=C 'TxtStage'
$TxtMessage=C 'TxtMessage'
$ProgressQc=C 'ProgressQc'
$TxtHeaderStatus=C 'TxtHeaderStatus'
$TxtFooter=C 'TxtFooter'

$TxtProfileDisplay.Text=[string]$profile.ProfileId + ' v' + [string]$profile.ProfileVersion
$expectedParts=@([string]$profile.Expected.CaseModel,[string]$profile.Expected.PsuModel,[string]$profile.Expected.CpuCoolerModel) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$TxtExpectedSummary.Text=$expectedParts -join ' | '
$TxtFooter.Text="Local baseline folder: $BaselineRoot  |  Connect the company USB only after QC is finished and SitecQC is closed."

$script:LastReport=$null
$script:Worker=$null
$script:StartedAt=$null
$script:CurrentStatus=$null
$script:Hardware=$null
$script:WorkRoot=$null

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
        if ([string]::IsNullOrWhiteSpace($TxtAssetId.Text)) { $TxtAssetId.Text=Get-SitecAutoAssetId -Hardware $h }

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
        else { $TxtMessage.Text='Hardware discovery completed. Confirm Asset ID, scan PSU serial and CPU ATPO, then run full QC. Tamper seal #1 follows Asset ID unless you overwrite it.' }
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message,'Hardware detection failed') | Out-Null
        $TxtHeaderStatus.Text='ERROR';$TxtStage.Text='Error';$TxtMessage.Text=$_.Exception.Message
    }
}

function Q([string]$s) { '"' + ($s -replace '"','\"') + '"' }
$BtnDetect.Add_Click({ Refresh-SitecHardware })
$TxtAssetId.Add_TextChanged({ $TxtSeal1.Text=$TxtAssetId.Text })
$TxtAssetId.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $TxtPsuSerial.Focus() | Out-Null; $_.Handled=$true } })
$TxtPsuSerial.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $TxtCpuAtpo.Focus() | Out-Null; $_.Handled=$true } })
$TxtCpuAtpo.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $TxtSeal1.Focus() | Out-Null; $_.Handled=$true } })
$TxtSeal1.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { $BtnRun.Focus() | Out-Null; $_.Handled=$true } })

$BtnRun.Add_Click({
    try {
        if ($script:Worker -and -not $script:Worker.HasExited) { return }
        if (-not $script:Hardware) { Refresh-SitecHardware }
        $usbStorage=@($script:Hardware.Storage | Where-Object { [string]$_.BusType -match '^(USB|SD|MMC)$' })
        if ($usbStorage.Count -gt 0) { throw 'Disconnect all USB/removable storage before QC so it is not included in the hardware inventory. Connect the company flash drive only after SitecQC is closed.' }
        $asset=$TxtAssetId.Text.Trim()
        if ($asset -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$') { throw 'Asset ID is invalid. Scan/enter a valid physical asset label.' }
        $required=@()
        if (Get-SitecCaptureFlag 'RequirePsuSerial' $true) { $required += [pscustomobject]@{Name='PSU serial';Value=$TxtPsuSerial.Text} }
        if (Get-SitecCaptureFlag 'RequireCpuAtpo' $true) { $required += [pscustomobject]@{Name='CPU ATPO';Value=$TxtCpuAtpo.Text} }
        if (Get-SitecCaptureFlag 'RequireSeal1' $true) { $required += [pscustomobject]@{Name='Tamper seal #1';Value=$TxtSeal1.Text} }
        foreach ($item in $required) { if ([string]::IsNullOrWhiteSpace([string]$item.Value)) { throw "$($item.Name) must be scanned or confirmed before final QC." } }

        $script:WorkRoot=New-SitecWorkingRoot -AssetId $asset -BaseDataRoot ([string]$context.Settings.DataRoot)
        $worker=Join-Path $root 'Invoke-SitecQC-Compact.ps1'
        $argList=@(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $worker),
            '-AssetId',(Q $asset),'-ProfileId',(Q ([string]$profile.ProfileId)),'-Operator',(Q $automaticOperator),
            '-CaseModel',(Q ([string]$profile.Expected.CaseModel)),'-PsuModel',(Q ([string]$profile.Expected.PsuModel)),'-PsuSerial',(Q $TxtPsuSerial.Text.Trim()),
            '-CpuAtpo',(Q $TxtCpuAtpo.Text.Trim()),'-Cooler',(Q ([string]$profile.Expected.CpuCoolerModel)),'-Seal1',(Q $TxtSeal1.Text.Trim()),
            '-BaselineRoot',(Q $BaselineRoot),'-WorkingRoot',(Q $script:WorkRoot)
        )
        $script:StartedAt=Get-Date;$script:CurrentStatus=$null;$script:LastReport=$null
        $script:Worker=Start-Process powershell.exe -ArgumentList ($argList -join ' ') -PassThru -WindowStyle Hidden
        $BtnRun.IsEnabled=$false;$BtnDetect.IsEnabled=$false;$BtnOpenLast.IsEnabled=$false
        $TxtHeaderStatus.Text='RUNNING';$TxtLog.Clear();$ProgressQc.Value=1;$TxtStage.Text='Starting';$TxtMessage.Text=("QC worker launched. Scratch data: {0} | Final output: {1}\Output" -f $script:WorkRoot,$BaselineRoot)
    } catch { [Windows.MessageBox]::Show($_.Exception.Message,'Cannot start QC') | Out-Null }
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
            if ($statusFile) { try { $s=Get-Content $statusFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json;$script:CurrentStatus=$s;$ProgressQc.Value=[int]$s.Percent;$TxtStage.Text=[string]$s.Stage;$TxtMessage.Text=[string]$s.Message;$log=Join-Path $s.RunPath 'worker.log';if (Test-Path $log) { $TxtLog.Text=Get-Content $log -Raw -Encoding UTF8;$TxtLog.ScrollToEnd() } } catch {} }
        }
    }
    if ($script:Worker.HasExited) {
        $BtnRun.IsEnabled=$true;$BtnDetect.IsEnabled=$true
        $published=Get-SitecPublishedCertificatePath -BaselineRoot $BaselineRoot -AssetId $asset
        if (Test-Path -LiteralPath $published) { $script:LastReport=$published }
        $BtnOpenLast.IsEnabled=[bool]$script:LastReport
        if ($script:Worker.ExitCode -eq 0) { $TxtHeaderStatus.Text='PASS';$TxtHeaderStatus.Foreground='#A8E6BE';$TxtMessage.Text="QC complete. PDF + Baseline JSON + Full JSON saved to $BaselineRoot\Output. Close SitecQC before connecting the archive USB." }
        elseif ($script:Worker.ExitCode -eq 2) { $TxtHeaderStatus.Text='FAIL';$TxtHeaderStatus.Foreground='#FFB4AB';$TxtMessage.Text="QC failed. PDF/Baseline/Full JSON and LastFailure diagnostics were saved to $BaselineRoot\Output." }
        else { $TxtHeaderStatus.Text='ERROR';$TxtHeaderStatus.Foreground='#FFB4AB';$TxtMessage.Text="QC error. Check $BaselineRoot\Output for LastFailure diagnostics." }
        $script:Worker=$null;$script:WorkRoot=$null
    }
})
$timer.Start()
$BtnOpenLast.Add_Click({ if ($script:LastReport -and (Test-Path $script:LastReport)) { Start-Process $script:LastReport } })

try { Ensure-SitecDependencies } catch {}
Refresh-SitecHardware
if (Get-SitecCaptureFlag 'RequirePsuSerial' $true) { $TxtPsuSerial.Focus() | Out-Null }
elseif (Get-SitecCaptureFlag 'RequireCpuAtpo' $true) { $TxtCpuAtpo.Focus() | Out-Null }
elseif (Get-SitecCaptureFlag 'RequireSeal1' $true) { $TxtSeal1.Focus() | Out-Null }
else { $BtnRun.Focus() | Out-Null }
[void]$window.ShowDialog()
