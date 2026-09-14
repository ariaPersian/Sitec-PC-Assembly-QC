$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-RamPresentation-Test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $run=[pscustomobject]@{
        AssetId='CASE-TEST';RunId='CASE-TEST-TEST';Operator='Tester';CompletedAt='2026-01-01T12:00:00+00:00';OverallStatus='PASS'
        Profile=[pscustomobject]@{ProfileId='TEST';ProfileVersion='1'}
        Physical=[pscustomobject]@{CaseModel='GREEN AVA+';PsuModel='GREEN GP700A-GED V3.1';PsuSerial='PSU001';Cooler='DeepCool AG400 PLUS';CpuAtpo='ATPO001';Seal1='CASE-TEST';Seal2=''}
        Hardware=[pscustomobject]@{
            ComputerName='TEST-PC'
            Motherboard=[pscustomobject]@{Manufacturer='ASUS';Model='TUF GAMING B760-PLUS WIFI';SerialNumber='MB001'}
            CPU=[pscustomobject]@{Model='Intel Core i7-14700K';Cores=20;LogicalProcessors=28}
            BIOS=[pscustomobject]@{Version='1836';ReleaseDate='2026-01-01'}
            Windows=[pscustomobject]@{Caption='Windows 10 Pro';Build='19045'}
            SystemUUID='UUID001'
            Memory=@([pscustomobject]@{Slot='A2';Manufacturer='Kingston';PartNumber='RAM-PART';SerialNumber='RAM001';CapacityGB=16;Type='DDR5';RatedSpeedMHz=5600;ConfiguredSpeedMHz=4800;ConfiguredVoltage_mV=1100})
            Storage=@();Graphics=@();Network=@()
        }
        BomValidation=[pscustomobject]@{Status='PASS'}
        Benchmark=[pscustomobject]@{
            WinSAT=[pscustomobject]@{Status='PASS';Available=$true;CpuCompressionMBps=100;MemoryMBps=50000}
            DiskSpd=[pscustomobject]@{Status='PASS';Available=$true;SequentialReadMBps=7000;SequentialWriteMBps=6000;RandomReadIOPS=900000}
            WHEA=[pscustomobject]@{Count=0}
            Stress=[pscustomobject]@{Status='SKIPPED'}
        }
        BenchmarkValidation=[pscustomobject]@{Status='PASS';Checks=@()}
        Security=[pscustomobject]@{HardwareIdentitySha256='HWID';Sha256='MANIFEST';Signed=$false}
    }
    $ctx=[pscustomobject]@{Settings=[pscustomobject]@{Reporting=[pscustomobject]@{CompanyName='SITEC';GeneratePdf=$false}}}

    $report=New-SitecCustomerReport -Run $run -RunPath $temp -Context $ctx
    if (-not (Test-Path -LiteralPath $report.HtmlPath)) { throw 'Customer report HTML was not generated.' }
    $html=Get-Content -LiteralPath $report.HtmlPath -Raw -Encoding UTF8

    if ($html -notmatch '<h2>Memory Modules</h2>') { throw 'Memory Modules section is missing.' }
    if ($html -notmatch '<th>Manufacturer</th>') { throw 'RAM Manufacturer column is missing.' }
    if ($html -notmatch '<td>Crucial</td>') { throw 'RAM Manufacturer is not normalized to Crucial in the PDF presentation.' }
    if ($html -match '<th>Part number</th>') { throw 'RAM Part number column must not be shown in the customer PDF.' }
    if ($html -match '<th>Serial</th>') { throw 'RAM Serial column must not be shown in the customer PDF.' }
    if ($html -match '<th>Speed</th>') { throw 'RAM Speed column must not be shown in the customer PDF.' }
    if ($html -match 'Kingston|RAM-PART|RAM001|4800 MHz') { throw 'Raw RAM brand/model/serial/speed leaked into the customer PDF presentation.' }

    if ($run.Hardware.Memory[0].Manufacturer -ne 'Kingston' -or $run.Hardware.Memory[0].PartNumber -ne 'RAM-PART' -or $run.Hardware.Memory[0].SerialNumber -ne 'RAM001' -or $run.Hardware.Memory[0].ConfiguredSpeedMHz -ne 4800) {
        throw 'PDF presentation policy mutated raw hardware evidence.'
    }

    $start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
    if ($start -notmatch [regex]::Escape('| Crucial | S/N')) { throw 'UI RAM line does not display Crucial.' }
    if ($start -match [regex]::Escape('$memory.Manufacturer) $($memory.PartNumber')) { throw 'UI RAM line still exposes detected RAM manufacturer/part number.' }

    Write-Host 'RAM UI/PDF presentation policy tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
