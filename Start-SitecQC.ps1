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
$script:CancelPath=$null

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
        else { $TxtMessage.Text='Hardware discovery completed. Confirm Asset ID, scan PSU serial and CPU ATPO, then run selected QC. BOM mismatches do not suppress selected benchmarks; they still affect the final QC status.' }
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
        $script:StartedAt=Get-Date;$script:CurrentStatus=$null;$script:LastReport=$null
        $script:Worker=Start-Process powershell.exe -ArgumentList ($argList -join ' ') -PassThru -WindowStyle Hidden
        $BtnRun.IsEnabled=$false;$BtnDetect.IsEnabled=$false;$BtnOpenLast.IsEnabled=$false
        $BtnCancel.Visibility='Visible';$BtnCancel.IsEnabled=$true
        @($ChkBenchCpu,$ChkBenchMemory,$ChkBenchDisk,$ChkBenchGraphics) | ForEach-Object { $_.IsEnabled=$false }
        $TxtHeaderStatus.Text='RUNNING';$TxtLog.Clear();$ProgressQc.Value=1;$TxtProgressPercent.Text='1%';$TxtElapsed.Text='Elapsed: 00:00';$TxtRemaining.Text='Remaining: --:--';$TxtStage.Text='Starting';$TxtMessage.Text=("QC worker launched for [{0}]. Scratch data: {1} | Final output: {2}\Output" -f $benchmarkCsv,$script:WorkRoot,$BaselineRoot)
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
                    if (Test-Path $log) { $TxtLog.Text=Get-Content $log -Raw -Encoding UTF8;$TxtLog.ScrollToEnd() }
                } catch {}
            }
        }
    }
    if ($script:Worker.HasExited) {
        $BtnRun.IsEnabled=$true;$BtnDetect.IsEnabled=$true
        $BtnCancel.IsEnabled=$false;$BtnCancel.Visibility='Collapsed'
        @($ChkBenchCpu,$ChkBenchMemory,$ChkBenchDisk,$ChkBenchGraphics) | ForEach-Object { $_.IsEnabled=$true }
        $published=Get-SitecPublishedCertificatePath -BaselineRoot $BaselineRoot -AssetId $asset
        if (Test-Path -LiteralPath $published) { $script:LastReport=$published }
        $BtnOpenLast.IsEnabled=[bool]$script:LastReport
        $ProgressQc.Value=100;$TxtProgressPercent.Text='100%'
        if($script:StartedAt){$TxtElapsed.Text=('Elapsed: '+(Format-SitecUiDuration (((Get-Date)-$script:StartedAt).TotalSeconds)))}
        $TxtRemaining.Text='Remaining: 00:00'
        if ($script:Worker.ExitCode -eq 0) {
            $TxtHeaderStatus.Text='PASS';$TxtHeaderStatus.Foreground='#A8E6BE';$TxtStage.Text='Complete'
            $TxtMessage.Text="QC complete: PASS. PDF + Baseline JSON + Full JSON saved to $BaselineRoot\Output. Close SitecQC before connecting the archive USB."
        }
        elseif ($script:Worker.ExitCode -eq 2) {
            $reason='';$publishedStatus='FAIL'
            $fullJson=Get-SitecPublishedFullJsonPath -BaselineRoot $BaselineRoot -AssetId $asset
            if (Test-Path -LiteralPath $fullJson) {
                try {
                    $full=Get-Content -LiteralPath $fullJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($full.PSObject.Properties['OverallStatus']) { $publishedStatus=[string]$full.OverallStatus }
                    if ($full.PSObject.Properties['ErrorSummary'] -and $full.ErrorSummary) { $reason=[string]$full.ErrorSummary.PrimaryMessage }
                } catch {}
            }
            if($publishedStatus -eq 'CANCELLED'){
                $TxtHeaderStatus.Text='CANCELLED';$TxtHeaderStatus.Foreground='#FFD166';$TxtStage.Text='Benchmark cancelled'
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason='Benchmark cancelled by operator.' }
                $TxtMessage.Text=("QC benchmark cancelled. {0} Partial PDF/Full JSON evidence was saved to {1}\Output." -f $reason,$BaselineRoot)
            } else {
                $TxtHeaderStatus.Text='FAIL';$TxtHeaderStatus.Foreground='#FFB4AB';$TxtStage.Text='Complete - QC FAIL'
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason='One or more QC validation gates failed.' }
                $TxtMessage.Text=("QC completed: FAIL. {0} PDF + Baseline JSON + Full JSON were saved to {1}\Output. This is a QC result, not an application error." -f $reason,$BaselineRoot)
            }
        }
        else {
            $TxtHeaderStatus.Text='ERROR';$TxtHeaderStatus.Foreground='#FFB4AB';$TxtStage.Text='Runtime error'
            $failureMessage=''
            $fullJson=Get-SitecPublishedFullJsonPath -BaselineRoot $BaselineRoot -AssetId $asset
            if(Test-Path -LiteralPath $fullJson){
                try {
                    $full=Get-Content -LiteralPath $fullJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    if($full.PSObject.Properties['ErrorSummary'] -and $full.ErrorSummary){$failureMessage=[string]$full.ErrorSummary.PrimaryMessage}
                } catch {}
            }
            $failureJson=Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ($asset+'-LastFailure.json')
            if (Test-Path -LiteralPath $failureJson) {
                try { $failureMessage=[string](Get-Content -LiteralPath $failureJson -Raw -Encoding UTF8 | ConvertFrom-Json).message } catch {}
            }
            if ([string]::IsNullOrWhiteSpace($failureMessage)) { $failureMessage='The QC application or publishing pipeline encountered a runtime error.' }
            $TxtMessage.Text=("QC runtime ERROR. {0} Check LastFailure diagnostics in {1}\Output." -f $failureMessage,$BaselineRoot)
        }
        $script:Worker=$null;$script:WorkRoot=$null;$script:CancelPath=$null
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
