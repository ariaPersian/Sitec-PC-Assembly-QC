#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$context=Get-SitecContext
$profile=Get-SitecProfile -Context $context -ProfileId 'B760-14700K-990PRO'

$cooler='DeepCool AG400 PLUS / XuanBing 400 V5 Dual Fan / P/N R-AG400-BKNNMD-G / EAN 6933412727767'
$psu='GREEN GP700A-GED V3.1 80PLUS BRONZE ATX3.1 700W'

$hardware=[pscustomobject]@{
    ComputerName='TEST-PC'
    SystemUUID='00112233-4455-6677-8899-AABBCCDDEEFF'
    SystemEnclosure=[pscustomobject]@{Manufacturer='';SerialNumber='';SMBIOSAssetTag='';PartNumber='';ChassisTypes=@(3)}
    Motherboard=[pscustomobject]@{Manufacturer='ASUSTeK COMPUTER INC.';Model='TUF GAMING B760-PLUS WIFI';Version='1.0';SerialNumber='MB123456'}
    CPU=[pscustomobject]@{Model='Intel(R) Core(TM) i7-14700K';Manufacturer='GenuineIntel';Socket='LGA1700';Cores=20;LogicalProcessors=28;MaxClockMHz=3400;ProcessorId='BFEBFBFF000B0671'}
    Memory=@([pscustomobject]@{Slot='Controller1-DIMM0';Bank='BANK 0';Manufacturer='Corsair';PartNumber='CMK32GX5M2B6400C36';SerialNumber='B500481E';CapacityGB=16;Type='DDR5';RatedSpeedMHz=4000;ConfiguredSpeedMHz=4000;ConfiguredVoltage_mV=1100})
    MemoryTotalGB=16
    Storage=@(
        [pscustomobject]@{FriendlyName='SanDisk 3.2Gen1';Model='SanDisk 3.2Gen1';SerialNumber='USB-SHOULD-NOT-BE-IDENTITY';FirmwareVersion='';MediaType='Unspecified';BusType='USB';SizeGB=57.3;HealthStatus='Healthy';Reliability=[pscustomobject]@{Available=$false}},
        [pscustomobject]@{FriendlyName='Samsung SSD 990 PRO 1TB';Model='Samsung SSD 990 PRO 1TB';SerialNumber='SSD123456';ControllerIdentifier='0025_3848_51A0_4F0E.';FirmwareVersion='5B2QJXD7';MediaType='SSD';BusType='NVMe';SizeGB=931.51;HealthStatus='Healthy';Reliability=[pscustomobject]@{Available=$false}}
    )
    BIOS=[pscustomobject]@{Manufacturer='American Megatrends';Version='1836';ReleaseDate='2026-04-16';SMBIOSVersion='3.7'}
    Graphics=@([pscustomobject]@{Name='Intel(R) UHD Graphics';AdapterRAMGB=1;DriverVersion='1.0';Status='OK'})
    Network=@()
    Windows=[pscustomobject]@{Caption='Microsoft Windows 10 Pro';Version='10.0.19045';Build='19045';Architecture='64-bit';InstallDate='2026-09-09T08:38:08'}
    PnPErrors=@()
}
$physical=[pscustomobject]@{CaseModel='GREEN AVA+';PsuModel=$psu;PsuSerial='PSU123';CpuAtpo='ATPO123';Cooler=$cooler;Seal1='SEAL001';Seal2=''}

$bom=Test-SitecExpectedBom -Hardware $hardware -Physical $physical -Profile $profile
if ($bom.Status -ne 'PASS') { throw 'BOM runtime test failed: ' + (($bom.Checks | Where-Object Status -ne 'PASS' | ForEach-Object Name) -join ', ') }
if (@($bom.Checks).Count -lt 10) { throw 'BOM validation returned an unexpectedly small check set.' }
$ssdCheck=$bom.Checks | Where-Object Name -eq 'SSD serial' | Select-Object -First 1
if ([string]$ssdCheck.Actual -match 'USB-SHOULD') { throw 'USB storage leaked into expected SSD identity validation.' }

# Compile and execute the native CPU/RAM workers briefly so Windows PowerShell 5.1
# incompatibilities are caught in CI without running the production 15-minute profile.
Initialize-SitecBurnInType
$ciCpu=[SitecQcBurnInV2]::CpuAsync(1,2,50).GetAwaiter().GetResult()
if ($ciCpu.Iterations -le 0 -or $ciCpu.Threads -ne 2) { throw 'CPU burn-in worker smoke test failed.' }
$ciMem=[SitecQcBurnInV2]::MemoryAsync(1,128,1).GetAwaiter().GetResult()
if ($ciMem.Errors -ne 0 -or $ciMem.AllocatedMB -lt 128 -or $ciMem.BytesVerified -le 0) { throw 'Memory burn-in worker smoke test failed.' }

$burnIn=[pscustomobject]@{
    Status='PASS';Required=$true;DurationSeconds=900;ActualSeconds=901.2
    CpuStress=[pscustomobject]@{Seconds=900;Threads=28;DutyPercent=85;HashWorkMBps=1234;WorkUnitsPerSecond=1234;Iterations=1000000}
    MemoryVerification=[pscustomobject]@{RequestedMB=9000;AllocatedMB=9000;VerifiedMB=900000;Errors=0;Seconds=900;Passes=100;TargetSystemUsagePercent=78}
    DiskStress=[pscustomobject]@{Enabled=$true;Status='PASS';ReadMBps=3500;ReadIOPS=55000;AverageReadLatencyMs=0.4;BlockSizeKB=64;QueueDepth=16;Threads=4;WritePercent=0}
    GraphicsStress=[pscustomobject]@{Enabled=$true;Required=$false;Status='PASS';Engine='WinSAT DWM composition workload'}
    Utilization=[pscustomobject]@{
        SampleCount=180
        CPU=[pscustomobject]@{Average=96.2;Peak=100;Samples=180}
        Memory=[pscustomobject]@{Average=77.4;Peak=80.1;Samples=180}
        Disk=[pscustomobject]@{Average=62.1;Peak=100;Samples=180}
        GPU=[pscustomobject]@{Average=28.5;Peak=44.0;Samples=180}
    }
    Sensors=@();LoadSamples=@()
}

$benchmark=[pscustomobject]@{
    BurnIn=$burnIn
    Stress=$burnIn
    WHEA=[pscustomobject]@{Count=0;Events=@()}
    WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuCompressionMBps=2531;MemoryMBps=28982}
    DiskSpd=[pscustomobject]@{Available=$true;Required=$true;Status='PASS';SequentialReadMBps=6422;SequentialWriteMBps=6501;RandomReadIOPS=589000}
}
$bench=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
if ($bench.Status -ne 'PASS') { throw 'Benchmark validation runtime test failed.' }
if (-not ($bench.Checks | Where-Object Name -eq 'CPU average load during burn-in')) { throw 'Burn-in utilization validation was not generated.' }

$serials=@(Get-SitecSerialSet -Hardware $hardware -Physical $physical -Profile $profile)
if ($serials.Count -lt 6) { throw 'Serial inventory runtime test failed.' }
if (@($serials | Where-Object Serial -eq 'USB-SHOULD-NOT-BE-IDENTITY').Count -ne 0) { throw 'USB storage leaked into fleet serial identity.' }

$temp=Join-Path $env:TEMP ('SitecQC-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $diskXml=Join-Path $temp 'diskspd.xml'
    @'
<Results><TimeSpan><TestTimeSeconds>8.00</TestTimeSeconds><Thread><Target><ReadBytes>53687091200</ReadBytes><ReadCount>51200</ReadCount><WriteBytes>0</WriteBytes><WriteCount>0</WriteCount><AverageReadLatencyMilliseconds>1.25</AverageReadLatencyMilliseconds></Target></Thread></TimeSpan></Results>
'@ | Set-Content -LiteralPath $diskXml -Encoding UTF8
    $dm=Get-SitecDiskSpdMetrics -XmlPath $diskXml
    if ([math]::Abs([double]$dm.ReadMBps-6400) -gt 0.1) { throw "DiskSpd XML parser runtime test failed: $($dm.ReadMBps) MB/s" }

    $manifestObject=[pscustomobject]@{AssetId='PC-TEST';Hardware=$hardware;Physical=$physical;Profile=$profile}
    $id1=New-SitecHardwareIdentity -Manifest $manifestObject
    $hardware.BIOS.Version='9999'
    $hardware.Windows.Build='99999'
    $id2=New-SitecHardwareIdentity -Manifest $manifestObject
    if ($id1.Sha256 -ne $id2.Sha256) { throw 'Hardware identity changed because of mutable BIOS/Windows data.' }
    $hardware.BIOS.Version='1836';$hardware.Windows.Build='19045'

    $context.Settings.Reporting.GeneratePdf=$false
    $run=[pscustomobject]@{
        AssetId='PC-TEST'
        RunId='PC-TEST-20260910-000000'
        Operator='CI'
        CompletedAt='2026-09-10T00:00:00'
        OverallStatus='PASS'
        Profile=$profile
        Physical=$physical
        Hardware=$hardware
        BomValidation=$bom
        Benchmark=$benchmark
        BenchmarkValidation=$bench
        PassMarkEvidence=@()
        Security=[pscustomobject]@{Signed=$false;Thumbprint='';Sha256='ABCDEF';HardwareIdentitySha256=$id1.Sha256}
    }
    $report=New-SitecCustomerReport -Run $run -RunPath $temp -Context $context
    if (-not (Test-Path -LiteralPath $report.HtmlPath)) { throw 'Customer report was not generated.' }
    $html=Get-Content -LiteralPath $report.HtmlPath -Raw
    if ($html -match '>N/A<') { throw 'Dynamic report rendered an N/A placeholder instead of omitting missing optional data.' }
    if ($html -notmatch 'DeepCool AG400 PLUS') { throw 'Production CPU cooler BOM is missing from the report.' }
    if ($html -match '<h2>Storage Reliability</h2>') { throw 'Dynamic report rendered an unavailable storage reliability section.' }

    $manifestPath=Join-Path $temp 'hardware-qc-manifest.json'
    $run | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $context.Settings.Security.SigningCertificateThumbprint=''
    $sec=Protect-SitecManifest -ManifestPath $manifestPath -Context $context
    if ([string]::IsNullOrWhiteSpace([string]$sec.HardwareIdentitySha256)) { throw 'Stable hardware identity SHA-256 was not generated.' }
    Write-SitecEvidenceHashes -RunPath $temp | Out-Null
    $html=Get-Content -LiteralPath $report.HtmlPath -Raw
    if ($html -notmatch 'Hardware Identity SHA-256') { throw 'Hardware identity hash was not injected into the customer certificate.' }
    if ($html -notmatch '<h2>Full System Burn-In</h2>') { throw 'Full-system burn-in summary was not injected into the customer certificate.' }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Runtime smoke tests passed.' -ForegroundColor Green
