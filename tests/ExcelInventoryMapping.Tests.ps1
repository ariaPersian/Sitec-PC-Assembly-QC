$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-ExcelMapping-Test-'+[guid]::NewGuid().ToString('N'))
$baselineRoot=Join-Path $temp 'BaselineQC'
try {
    Initialize-SitecBaselineLayout -BaselineRoot $baselineRoot | Out-Null
    $pdf=Join-Path $temp 'CASE-TEST-QC-Certificate.pdf'
    'PDF' | Set-Content -LiteralPath $pdf -Encoding ASCII

    $manifestObject=[pscustomobject]@{
        AssetId='PC-001';CompletedAt='2026-09-12T14:30:00+03:30';OverallStatus='PASS'
        Physical=[pscustomobject]@{Seal1='PC-001';CaseModel='AVA+ Green';CpuAtpo='M6M71N2102883';Cooler='DeepCool AG400 Plus Dual Fan';PsuModel='GP700A-GED V3.1 700W Green';PsuSerial='4001956915379'}
        Hardware=[pscustomobject]@{
            Motherboard=[pscustomobject]@{Manufacturer='ASUS';Model='B760-PLUS WIFI';SerialNumber='MB001'}
            CPU=[pscustomobject]@{Model='Intel Core i7-14700K';Cores=20;LogicalProcessors=28}
            Memory=@([pscustomobject]@{Slot='A2';Manufacturer='Kingston';PartNumber='KF548C38';SerialNumber='RAM001';CapacityGB=16;ConfiguredSpeedMHz=4800})
            Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';FriendlyName='Samsung SSD 990 PRO 1TB';SerialNumber='S7LANU0Y800504';FirmwareVersion='5B2QJXD7';SizeGB=1000;BusType='NVMe'})
            BIOS=[pscustomobject]@{Version='1836';ReleaseDate='2026-01-01'}
            Graphics=@([pscustomobject]@{Name='Intel UHD Graphics 770'})
            SystemUUID='UUID001'
        }
        Profile=[pscustomobject]@{ProfileId='B760-14700K-990PRO';ProfileVersion='3';Expected=[pscustomobject]@{StorageModelContains='990 PRO'}}
        Security=[pscustomobject]@{HardwareIdentitySchema='SITEC-HWID-V2';HardwareIdentitySha256='HWID123';Sha256='MANIFEST123'}
        BenchmarkValidation=[pscustomobject]@{Status='PASS'}
    }
    $manifest=Join-Path $temp 'hardware-qc-manifest.json'
    $manifestObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest -Encoding UTF8

    $path=Publish-SitecBaselineJson -BaselineRoot $baselineRoot -AssetId 'PC-001' -ManifestPath $manifest -CertificatePath $pdf
    $b=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($b.Schema -ne 'SITEC-BASELINE-V2') { throw 'Baseline schema was not upgraded to V2.' }
    $x=$b.ExcelInventory
    if ($x.'PC Tag ID' -ne 'PC-001') { throw 'PC Tag ID mapping failed.' }
    if ($x.Benchmark -ne [string][char]0x2713) { throw 'Benchmark PASS mark mapping failed.' }
    if ($x.'BenchMark Files' -ne 'CASE-TEST-QC-Certificate.pdf') { throw 'Certificate filename mapping failed.' }
    if ($x.'Build Status' -ne 'PASS') { throw 'Build Status mapping failed.' }
    if ($x.'Motherboard Model' -ne 'ASUS B760-PLUS WIFI') { throw 'Motherboard model mapping failed.' }
    if ($x.'Motherboard Serial No' -ne 'MB001') { throw 'Motherboard serial mapping failed.' }
    if ($x.'CPU ATPO' -ne 'M6M71N2102883') { throw 'CPU ATPO mapping failed.' }
    if ($x.'RAM Model' -notmatch 'Kingston KF548C38') { throw 'RAM model mapping failed.' }
    if ($x.'RAM Serial No' -ne 'RAM001') { throw 'RAM serial mapping failed.' }
    if ($x.'SSD Serial No' -ne 'S7LANU0Y800504') { throw 'SSD serial mapping failed.' }
    if ($x.'PSU Serial No' -ne '4001956915379') { throw 'PSU serial mapping failed.' }
    if ($x.'Tamper Seal #1' -ne 'PC-001') { throw 'Tamper seal mapping failed.' }
    if ($x.'Hardware Identity SHA-256' -ne 'HWID123') { throw 'HWID mapping failed.' }
    if ($x.'Manifest SHA-256' -ne 'MANIFEST123') { throw 'Manifest hash mapping failed.' }
    if ($x.'QC Date' -ne '2026-09-12T14:30:00+03:30') { throw 'QC Date mapping failed.' }
    if ($x.'CPU ' -ne '' -or $x.'SSD' -ne '' -or $x.'Win10' -ne '') { throw 'Manual assembly columns must remain empty in SitecQC mapping.' }

    Write-Host 'Excel inventory mapping tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
