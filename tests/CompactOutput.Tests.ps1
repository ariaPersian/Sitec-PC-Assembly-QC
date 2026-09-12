$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-BaselineOutput-Test-'+[guid]::NewGuid().ToString('N'))
$baselineRoot=Join-Path $temp 'BaselineQC'
try {
    $layout=Initialize-SitecBaselineLayout -BaselineRoot $baselineRoot
    if (-not (Test-Path -LiteralPath $layout.OutputRoot)) { throw 'BaselineQC Output folder was not created.' }

    $source=Join-Path $temp 'new.pdf'
    'PDF-DATA' | Set-Content -LiteralPath $source -Encoding ASCII
    $published=Publish-SitecCertificate -BaselineRoot $baselineRoot -AssetId 'CASE-TEST' -SourcePdf $source
    if (-not (Test-Path -LiteralPath $published)) { throw 'Final PDF was not published locally.' }
    if ($published -ne (Join-Path $layout.OutputRoot 'CASE-TEST-QC-Certificate.pdf')) { throw 'Published PDF path is not stable.' }

    $manifestObject=[pscustomobject]@{
        AssetId='CASE-TEST';CompletedAt='2026-01-01T12:00:00Z';OverallStatus='PASS'
        Physical=[pscustomobject]@{Seal1='CASE-TEST';CaseModel='GREEN AVA+';CpuAtpo='M6M71N2102883';Cooler='DeepCool AG400 PLUS';PsuModel='GREEN GP700A-GED V3.1';PsuSerial='PSU001'}
        Hardware=[pscustomobject]@{
            Motherboard=[pscustomobject]@{Manufacturer='ASUS';Model='TUF GAMING B760-PLUS WIFI';SerialNumber='MB001'}
            CPU=[pscustomobject]@{Model='Intel Core i7-14700K';Cores=20;LogicalProcessors=28}
            MemoryTotalGB=16
            Memory=@([pscustomobject]@{Slot='A2';Manufacturer='Kingston';PartNumber='RAM-PART';SerialNumber='RAM001';CapacityGB=16;ConfiguredSpeedMHz=4800})
            Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';FriendlyName='Samsung SSD 990 PRO 1TB';SerialNumber='SSD001';FirmwareVersion='FW1';SizeGB=1000;BusType='NVMe'})
            BIOS=[pscustomobject]@{Version='1836';ReleaseDate='2026-01-01'}
            Graphics=@([pscustomobject]@{Name='Intel UHD Graphics'})
            SystemUUID='UUID001'
        }
        Profile=[pscustomobject]@{ProfileId='B760-14700K-990PRO';ProfileVersion='3';Expected=[pscustomobject]@{StorageModelContains='990 PRO'}}
        Security=[pscustomobject]@{HardwareIdentitySchema='SITEC-HWID-V2';HardwareIdentitySha256='HWID';Sha256='MANIFEST'}
    }
    $manifest=Join-Path $temp 'hardware-qc-manifest.json'
    $manifestObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $baseline=Publish-SitecBaselineJson -BaselineRoot $baselineRoot -AssetId 'CASE-TEST' -ManifestPath $manifest -CertificatePath $published
    if (-not (Test-Path -LiteralPath $baseline)) { throw 'Compact Baseline JSON was not published.' }
    $b=Get-Content -LiteralPath $baseline -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($b.AssetId -ne 'CASE-TEST' -or $b.CPU.Atpo -ne 'M6M71N2102883' -or $b.HardwareIdentity.Sha256 -ne 'HWID') { throw 'Baseline JSON contents are incomplete.' }

    $visible=@(Get-ChildItem -LiteralPath $layout.OutputRoot -File | Sort-Object Name)
    if ($visible.Count -ne 2) { throw "PASS output should contain exactly PDF + Baseline JSON; found $($visible.Count)." }

    $work=New-SitecWorkingRoot
    'temp' | Set-Content -LiteralPath (Join-Path $work 'x.tmp')
    Remove-SitecLocalQcResidue -WorkingRoot $work
    if (Test-Path -LiteralPath $work) { throw 'Temporary QC workspace was not removed.' }

    $start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
    if ($start -notmatch 'Get-SitecBaselineRoot') { throw 'GUI does not derive its local BaselineQC root from the launcher folder.' }
    if ($start -notmatch 'New-SitecWorkingRoot') { throw 'GUI does not use a disposable temp workspace.' }
    if ($start -notmatch '-BaselineRoot') { throw 'GUI does not pass the local BaselineQC root to the worker.' }
    if ($start -match 'Get-SitecEvidenceArchiveRoot') { throw 'Obsolete USB-only archive discovery is still active.' }
    if ($start -notmatch 'Disconnect all USB/removable storage before QC') { throw 'GUI does not protect the baseline from removable storage contamination.' }

    $launcher=Get-Content -LiteralPath (Join-Path $root 'launcher\Program.cs') -Raw -Encoding UTF8
    if ($launcher -match 'CommonApplicationData') { throw 'Launcher still extracts persistent payload under ProgramData.' }
    if ($launcher -notmatch 'Path.GetTempPath') { throw 'Launcher does not use a temporary payload folder.' }
    if ($launcher -notmatch 'WaitForExit') { throw 'Launcher cannot clean its temporary payload after the UI exits.' }

    Write-Host 'BaselineQC local PDF + Baseline JSON output tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
