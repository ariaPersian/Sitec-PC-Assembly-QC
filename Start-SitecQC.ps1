#requires -version 5.1
[CmdletBinding()]
param([string]$DataRoot='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $args="-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    if ($DataRoot) { $args += " -DataRoot `"$DataRoot`"" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args
    exit
}
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$context=Get-SitecContext -DataRoot $DataRoot
$profile=Get-SitecProfile -Context $context -ProfileId ([string]$context.Settings.DefaultProfileId)
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
[xml]$xaml=Get-Content -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Raw
$reader=New-Object System.Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
function C([string]$n){$window.FindName($n)}
$TxtAssetId=C 'TxtAssetId'; $TxtProfile=C 'TxtProfile'; $TxtOperator=C 'TxtOperator'; $TxtDataRoot=C 'TxtDataRoot'
$TxtCase=C 'TxtCase'; $TxtPsuModel=C 'TxtPsuModel'; $TxtPsuSerial=C 'TxtPsuSerial'; $TxtCpuAtpo=C 'TxtCpuAtpo'; $TxtCooler=C 'TxtCooler'; $TxtSeal1=C 'TxtSeal1'; $TxtSeal2=C 'TxtSeal2'
$BtnDetect=C 'BtnDetect'; $BtnRun=C 'BtnRun'; $BtnOpenLast=C 'BtnOpenLast'; $TxtHardware=C 'TxtHardware'; $TxtLog=C 'TxtLog'; $TxtStage=C 'TxtStage'; $TxtMessage=C 'TxtMessage'; $ProgressQc=C 'ProgressQc'; $TxtHeaderStatus=C 'TxtHeaderStatus'; $TxtFooter=C 'TxtFooter'
$TxtProfile.Text=[string]$profile.ProfileId; $TxtOperator.Text=$env:USERNAME; $TxtDataRoot.Text=[string]$context.Settings.DataRoot; $TxtCase.Text=[string]$profile.Expected.CaseModel; $TxtPsuModel.Text=[string]$profile.Expected.PsuModel
$script:LastReport=$null; $script:Worker=$null; $script:StartedAt=$null; $script:CurrentStatus=$null

$BtnDetect.Add_Click({
    try {
        $TxtHeaderStatus.Text='DETECTING'; $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        $h=Get-SitecHardwareInventory
        $lines=@(
            "Computer   : $($h.ComputerName)",
            "Board      : $($h.Motherboard.Manufacturer) $($h.Motherboard.Model)",
            "Board S/N  : $($h.Motherboard.SerialNumber)",
            "CPU        : $($h.CPU.Model) [$($h.CPU.Cores)C/$($h.CPU.LogicalProcessors)T]",
            "BIOS       : $($h.BIOS.Version) ($($h.BIOS.ReleaseDate))",
            "RAM        : $($h.MemoryTotalGB) GB",
            ($h.Memory | ForEach-Object { "  RAM       : $($_.Slot) | $($_.Manufacturer) $($_.PartNumber) | S/N $($_.SerialNumber) | $($_.ConfiguredSpeedMHz) MHz" }),
            ($h.Storage | ForEach-Object { "  STORAGE   : $($_.Model) | S/N $($_.SerialNumber) | $($_.SizeGB) GB | $($_.BusType)" }),
            ($h.Graphics | ForEach-Object { "  GPU       : $($_.Name)" }),
            "PnP Errors : $(@($h.PnPErrors).Count)"
        )
        $TxtHardware.Text=($lines -join [Environment]::NewLine); $TxtHeaderStatus.Text='READY'
    } catch { [Windows.MessageBox]::Show($_.Exception.Message,'Hardware detection failed') | Out-Null; $TxtHeaderStatus.Text='ERROR' }
})

function Q([string]$s) { '"' + ($s -replace '"','\"') + '"' }
$BtnRun.Add_Click({
    try {
        if ($script:Worker -and -not $script:Worker.HasExited) { return }
        $asset=$TxtAssetId.Text.Trim()
        if ($asset -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$') { throw 'Enter a valid Asset ID, for example PC-001.' }
        foreach ($required in @(@('PSU serial',$TxtPsuSerial.Text),@('CPU ATPO',$TxtCpuAtpo.Text),@('CPU cooler',$TxtCooler.Text),@('Seal #1',$TxtSeal1.Text))) {
            if ([string]::IsNullOrWhiteSpace($required[1])) { throw "$($required[0]) is required before final QC." }
        }
        $worker=Join-Path $root 'Invoke-SitecQC.ps1'
        $argList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Q $worker),'-AssetId',(Q $asset),'-ProfileId',(Q $TxtProfile.Text.Trim()),'-Operator',(Q $TxtOperator.Text.Trim()),'-CaseModel',(Q $TxtCase.Text.Trim()),'-PsuModel',(Q $TxtPsuModel.Text.Trim()),'-PsuSerial',(Q $TxtPsuSerial.Text.Trim()),'-CpuAtpo',(Q $TxtCpuAtpo.Text.Trim()),'-Cooler',(Q $TxtCooler.Text.Trim()),'-Seal1',(Q $TxtSeal1.Text.Trim()),'-Seal2',(Q $TxtSeal2.Text.Trim()),'-DataRoot',(Q $TxtDataRoot.Text.Trim()))
        $script:StartedAt=Get-Date; $script:CurrentStatus=$null; $script:LastReport=$null
        $script:Worker=Start-Process powershell.exe -ArgumentList ($argList -join ' ') -PassThru -WindowStyle Hidden
        $BtnRun.IsEnabled=$false; $BtnDetect.IsEnabled=$false; $BtnOpenLast.IsEnabled=$false; $TxtHeaderStatus.Text='RUNNING'; $TxtLog.Clear(); $ProgressQc.Value=1; $TxtStage.Text='Starting'; $TxtMessage.Text='Worker launched...'
    } catch { [Windows.MessageBox]::Show($_.Exception.Message,'Cannot start QC') | Out-Null }
})

$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if (-not $script:Worker) { return }
    $asset=$TxtAssetId.Text.Trim(); $assetRoot=Join-Path $TxtDataRoot.Text.Trim() ("Assets\$asset\Runs")
    if (Test-Path $assetRoot) {
        $statusFile=Get-ChildItem -LiteralPath $assetRoot -Filter status.json -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $script:StartedAt.AddSeconds(-2) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($statusFile) {
            try {
                $s=Get-Content $statusFile.FullName -Raw | ConvertFrom-Json; $script:CurrentStatus=$s; $ProgressQc.Value=[int]$s.Percent; $TxtStage.Text=[string]$s.Stage; $TxtMessage.Text=[string]$s.Message
                $log=Join-Path $s.RunPath 'worker.log'; if (Test-Path $log) { $TxtLog.Text=Get-Content $log -Raw; $TxtLog.ScrollToEnd() }
                if ($s.State -eq 'COMPLETE') {
                    $resultPath=Join-Path $s.RunPath 'result.json'; if (Test-Path $resultPath) { $r=Get-Content $resultPath -Raw | ConvertFrom-Json; $script:LastReport=if($r.Pdf){$r.Pdf}else{$r.Html} }
                }
            } catch {}
        }
    }
    if ($script:Worker.HasExited) {
        $BtnRun.IsEnabled=$true; $BtnDetect.IsEnabled=$true; $BtnOpenLast.IsEnabled=[bool]$script:LastReport
        if ($script:Worker.ExitCode -eq 0) { $TxtHeaderStatus.Text='PASS'; $TxtHeaderStatus.Foreground='#A8E6BE' } elseif ($script:Worker.ExitCode -eq 2) { $TxtHeaderStatus.Text='FAIL'; $TxtHeaderStatus.Foreground='#FFB4AB' } else { $TxtHeaderStatus.Text='ERROR'; $TxtHeaderStatus.Foreground='#FFB4AB' }
        $script:Worker=$null
    }
})
$timer.Start()
$BtnOpenLast.Add_Click({ if ($script:LastReport -and (Test-Path $script:LastReport)) { Start-Process $script:LastReport } })
[void]$window.ShowDialog()
