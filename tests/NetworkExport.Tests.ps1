$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path ([IO.Path]::GetTempPath()) ('SitecQC-NetworkExport-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $context=[pscustomobject]@{ Settings=[pscustomobject]@{ NetworkExport=[pscustomobject]@{
        Enabled=$true
        SharePath='\\10.50.50.20\QC-Results'
        Username='QCTransfer'
        AutoExport=$true
        RetryCount=3
        RetryDelaySeconds=2
    }}}

    $defaults=Get-SitecNetworkExportSettings -Context $context -LauncherDir $temp
    if ($defaults.SharePath -ne '\\10.50.50.20\QC-Results') { throw 'Default network export path mismatch.' }
    if ($defaults.Username -ne 'QCTransfer') { throw 'Default network export username mismatch.' }
    if (-not $defaults.AutoExport) { throw 'Auto export must be enabled by default.' }

    Save-SitecNetworkExportSettings -LauncherDir $temp -Enabled $true -SharePath '\\10.50.50.20\QC-Results' -Username 'QCTransfer' -AutoExport $false -RetryCount 4 -RetryDelaySeconds 1 | Out-Null
    $saved=Get-SitecNetworkExportSettings -Context $context -LauncherDir $temp
    if ($saved.AutoExport) { throw 'Local network export override was not loaded.' }
    if ($saved.RetryCount -ne 4) { throw 'Network export retry setting was not persisted.' }

    $baselineRoot=Join-Path $temp 'BaselineQC'
    $layout=Initialize-SitecBaselineLayout -BaselineRoot $baselineRoot
    $asset='PC-001'
    $certificate=Get-SitecPublishedCertificatePath -BaselineRoot $baselineRoot -AssetId $asset
    $fullJson=Get-SitecPublishedFullJsonPath -BaselineRoot $baselineRoot -AssetId $asset
    $baseline=Get-SitecPublishedBaselinePath -BaselineRoot $baselineRoot -AssetId $asset
    'PDF-CONTENT' | Set-Content -LiteralPath $certificate -Encoding ASCII
    '{"asset":"PC-001","status":"PASS"}' | Set-Content -LiteralPath $fullJson -Encoding UTF8
    '{"legacy":"temporary"}' | Set-Content -LiteralPath $baseline -Encoding UTF8

    $collector=Join-Path $temp 'collector'
    New-Item -ItemType Directory -Path $collector -Force | Out-Null
    $export=Invoke-SitecNetworkExport -AssetId $asset -SharePath $collector -Files @($fullJson,$certificate) -RetryCount 1 -RetryDelaySeconds 0
    if (-not $export.Success -or -not $export.Verified) { throw ('Network export did not report a verified success: '+$export.Message) }

    $remoteRoot=Join-Path $collector $asset
    $remoteFull=Join-Path $remoteRoot ([IO.Path]::GetFileName($fullJson))
    $remotePdf=Join-Path $remoteRoot ([IO.Path]::GetFileName($certificate))
    if (-not (Test-Path -LiteralPath $remoteFull) -or -not (Test-Path -LiteralPath $remotePdf)) { throw 'Collector does not contain both Full JSON and QC Certificate PDF.' }
    if ((Get-FileHash -LiteralPath $remoteFull -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $fullJson -Algorithm SHA256).Hash) { throw 'Remote Full JSON hash mismatch.' }
    if ((Get-FileHash -LiteralPath $remotePdf -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $certificate -Algorithm SHA256).Hash) { throw 'Remote QC Certificate hash mismatch.' }
    if (Test-Path -LiteralPath (Join-Path $remoteRoot ([IO.Path]::GetFileName($baseline)))) { throw 'Baseline JSON must not be transferred to the collector.' }

    $retention=Remove-SitecLocalMachineReadableOutputAfterTransfer -BaselineRoot $baselineRoot -AssetId $asset
    if (-not $retention.Success) { throw ('Local retention cleanup failed: '+$retention.Message) }
    if (-not (Test-Path -LiteralPath $certificate)) { throw 'QC Certificate PDF must remain on the tested PC.' }
    if (Test-Path -LiteralPath $fullJson) { throw 'Full JSON must be removed from the tested PC after verified transfer.' }
    if (Test-Path -LiteralPath $baseline) { throw 'Baseline JSON must not remain on the tested PC after verified transfer.' }

    $remaining=@(Get-ChildItem -LiteralPath $layout.OutputRoot -File)
    if ($remaining.Count -ne 1 -or $remaining[0].Name -ne ([IO.Path]::GetFileName($certificate))) {
        throw 'After verified transfer the tested PC must retain only the QC Certificate PDF.'
    }

    $startUi=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
    if (-not $startUi.Contains('Add_ContentRendered')) { throw 'GUI does not schedule an automatic startup network test after rendering.' }
    if (-not $startUi.Contains("Start-SitecNetworkProbe -Reason 'startup'")) { throw 'Startup network test is not invoked automatically.' }
    if (-not $startUi.Contains("tools\Test-NetworkExportWorker.ps1")) { throw 'GUI does not use the dedicated background network-test worker.' }
    if (-not $startUi.Contains('$networkTimer=New-Object Windows.Threading.DispatcherTimer')) { throw 'GUI does not poll the background network test asynchronously.' }
    if ($startUi.Contains('Test-SitecNetworkExportConnection -SharePath $TxtNetworkSharePath')) { throw 'Network Test button still performs the SMB test synchronously on the UI thread.' }
    if (-not $startUi.Contains('operator input remains available')) { throw 'Network test status does not make the non-blocking behavior explicit.' }

    $xaml=Get-Content -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
    if (-not $xaml.Contains('x:Name="BtnOpenNetworkPath"')) { throw 'Network settings UI does not expose the Open collector button.' }
    if (-not $xaml.Contains('Content="Open"')) { throw 'Collector action is not labelled Open.' }
    if ($xaml.Contains('BtnCopyNetworkPath')) { throw 'Legacy Copy network button is still present.' }

    if (-not $startUi.Contains('$BtnOpenNetworkPath=C ''BtnOpenNetworkPath''')) { throw 'GUI does not bind the Open collector button.' }
    if (-not $startUi.Contains('Open-SitecNetworkExportExplorer -SharePath $path -Username $user')) { throw 'Open collector button does not use the SMB Explorer helper.' }
    if ($startUi.Contains('[Windows.Clipboard]::SetText($path)')) { throw 'Legacy clipboard-copy behavior is still wired to the collector path.' }

    $networkModule=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZZZZZZZZZZZZZZZZZZZ-NetworkExport.ps1') -Raw -Encoding UTF8
    if (-not $networkModule.Contains('function Open-SitecNetworkExportExplorer')) { throw 'Network export module does not provide the Explorer open helper.' }
    if (-not $networkModule.Contains("Start-Process -FilePath 'explorer.exe'")) { throw 'Explorer helper does not launch Windows Explorer.' }
    if (-not $networkModule.Contains('Windows stored SMB credential')) { throw 'Explorer helper does not document stored-credential authentication.' }

    if (-not $xaml.Contains('x:Name="PwdNetworkPassword"')) { throw 'Network settings UI does not expose a PasswordBox.' }
    if (-not $xaml.Contains('Text="CASE-"')) { throw 'Asset ID field does not default to CASE-.' }
    if (-not $startUi.Contains('$PwdNetworkPassword=C ''PwdNetworkPassword''')) { throw 'GUI does not bind the network password field.' }
    if (-not $startUi.Contains('Set-SitecNetworkExportCredential -SharePath $sharePath -Username $username -Password $password')) { throw 'Password field is not wired to Windows Credential Manager.' }
    if (-not $startUi.Contains('$TxtAssetId.Text=''CASE-''')) { throw 'GUI does not restore CASE- when Asset ID is empty.' }
    if (-not $startUi.Contains('$asset -eq ''CASE-''')) { throw 'GUI does not reject the incomplete CASE- Asset ID.' }

    $networkModule=Get-Content -LiteralPath (Join-Path $root 'src\Functions\ZZZZZZZZZZZZZZZZZZZZZZZZZZ-NetworkExport.ps1') -Raw -Encoding UTF8
    if (-not $networkModule.Contains('function Set-SitecNetworkExportCredential')) { throw 'Network export module does not provide credential update support.' }
    if (-not $networkModule.Contains('CredWriteW')) { throw 'Collector password is not written through Windows Credential Manager API.' }

    $repoFiles=@(
        (Join-Path $root 'config\appsettings.json'),
        (Join-Path $root 'Start-SitecQC.ps1'),
        (Join-Path $root 'ui\MainWindow.xaml')
    )
    foreach($repoFile in $repoFiles){
        $content=Get-Content -LiteralPath $repoFile -Raw -Encoding UTF8
        if($content -match '(?i)"Password"\s*:\s*"[^"]+"'){ throw "A plaintext password was committed to $repoFile." }
    }

    Write-Host 'Network export and local-retention tests passed.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
