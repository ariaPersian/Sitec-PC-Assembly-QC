#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force
$context=Get-SitecContext
$profile=Get-SitecProfile -Context $context -ProfileId 'B760-14700K-990PRO'

$hardware=[pscustomobject]@{
    ComputerName='TEST-PC'
    SystemUUID='00112233-4455-6677-8899-AABBCCDDEEFF'
    SystemEnclosure=[pscustomobject]@{Manufacturer='';SerialNumber='';SMBIOSAssetTag='';PartNumber='';ChassisTypes=@(3)}
    Motherboard=[pscustomobject]@{Manufacturer='ASUSTeK COMPUTER INC.';Model='TUF GAMING B760-PLUS WIFI';Version='1.0';SerialNumber='MB123456'}
    CPU=[pscustomobject]@{Model='Intel(R) Core(TM) i7-14700K';Manufacturer='GenuineIntel';Socket='LGA1700';Cores=20;LogicalProcessors=28;MaxClockMHz=3400;ProcessorId='BFEBFBFF000B0671'}
    Memory=@([pscustomobject]@{Slot='Controller1-DIMM0';Bank='BANK 0';Manufacturer='Corsair';PartNumber='CMK32GX5M2B6400C36';SerialNumber='B500481E';CapacityGB=16;Type='DDR5';RatedSpeedMHz=4000;ConfiguredSpeedMHz=4000;ConfiguredVoltage_mV=1100})
    MemoryTotalGB=16
    Storage=@([pscustomobject]@{FriendlyName='Samsung SSD 990 PRO 1TB';Model='Samsung SSD 990 PRO 1TB';SerialNumber='SSD123456';FirmwareVersion='5B2QJXD7';MediaType='SSD';BusType='NVMe';SizeGB=931.51;HealthStatus='Healthy';Reliability=[pscustomobject]@{Available=$false}})
    BIOS=[pscustomobject]@{Manufacturer='American Megatrends';Version='1836';ReleaseDate='2026-04-16';SMBIOSVersion='3.7'}
    Graphics=@([pscustomobject]@{Name='Intel(R) UHD Graphics';AdapterRAMGB=1;DriverVersion='1.0';Status='OK'})
    Network=@()
    Windows=[pscustomobject]@{Caption='Microsoft Windows 10 Pro';Version='10.0.19045';Build='19045';Architecture='64-bit';InstallDate='2026-09-09T08:38:08'}
    PnPErrors=@()
}
$physical=[pscustomobject]@{CaseModel='GREEN AVA+';PsuModel='GREEN GP700A-GED V3.1 700W';PsuSerial='PSU123';CpuAtpo='ATPO123';Cooler='';Seal1='SEAL001';Seal2=''}

$bom=Test-SitecExpectedBom -Hardware $hardware -Physical $physical -Profile $profile
if ($bom.Status -ne 'PASS') { throw 'BOM runtime test failed: ' + (($bom.Checks | Where-Object Status -ne 'PASS' | ForEach-Object Name) -join ', ') }
if (@($bom.Checks).Count -lt 10) { throw 'BOM validation returned an unexpectedly small check set.' }

$benchmark=[pscustomobject]@{
    Stress=[pscustomobject]@{Status='PASS';MemoryVerification=[pscustomobject]@{Errors=0};CpuStress=[pscustomobject]@{Seconds=30;HashWorkMBps=100};Sensors=@()}
    WHEA=[pscustomobject]@{Count=0;Events=@()}
    WinSAT=[pscustomobject]@{Available=$true;Status='PASS';CpuCompressionMBps=350;MemoryMBps=18000}
    DiskSpd=[pscustomobject]@{Available=$true;Required=$true;Status='PASS';SequentialReadMBps=3000;SequentialWriteMBps=2200;RandomReadIOPS=50000}
}
$bench=Test-SitecBenchmarkResults -Benchmark $benchmark -Profile $profile
if ($bench.Status -ne 'PASS') { throw 'Benchmark validation runtime test failed.' }

$serials=@(Get-SitecSerialSet -Hardware $hardware -Physical $physical)
if ($serials.Count -lt 6) { throw 'Serial inventory runtime test failed.' }

Write-Host 'Runtime smoke tests passed.' -ForegroundColor Green
