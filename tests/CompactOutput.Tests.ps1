$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-PortableOutput-Test-'+[guid]::NewGuid().ToString('N'))
$archive=Join-Path $temp 'USB\SitecQC-Archive'
$work=Join-Path $temp 'work'
try {
    $layout=Initialize-SitecPortableArchive -ArchiveRoot $archive
    if (-not (Test-Path -LiteralPath $layout.ReportRoot)) { throw 'USB Reports folder was not created.' }
    if (-not (Test-Path -LiteralPath $layout.StateRoot)) { throw 'USB hidden state folder was not created.' }
    if (-not (Test-Path -LiteralPath $layout.FailureRoot)) { throw 'USB Failures folder was not created.' }

    # Seed/sync the exact files used by duplicate detection and baseline comparison.
    'AssetId,RunId,Type,Serial,Timestamp' | Set-Content -LiteralPath (Join-Path $layout.StateRoot 'fleet-serial-index.csv') -Encoding ASCII
    'AssetId,RunId,Timestamp' | Set-Content -LiteralPath (Join-Path $layout.StateRoot 'fleet-runs.csv') -Encoding ASCII
    $base=Join-Path $layout.StateRoot 'Assets\CASE-TEST\Baseline'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    '{"AssetId":"CASE-TEST"}' | Set-Content -LiteralPath (Join-Path $base 'hardware-qc-manifest.json') -Encoding UTF8

    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Seed-SitecWorkingState -ArchiveRoot $archive -WorkingRoot $work
    if (-not (Test-Path -LiteralPath (Join-Path $work 'fleet-serial-index.csv'))) { throw 'Fleet serial index was not staged from USB.' }
    if (-not (Test-Path -LiteralPath (Join-Path $work 'Assets\CASE-TEST\Baseline\hardware-qc-manifest.json'))) { throw 'Baseline was not staged from USB.' }

    $source=Join-Path $temp 'new.pdf'
    'PDF-DATA' | Set-Content -LiteralPath $source -Encoding ASCII
    $published=Publish-SitecCertificate -ArchiveRoot $archive -AssetId 'CASE-TEST' -SourcePdf $source
    if (-not (Test-Path -LiteralPath $published)) { throw 'Final PDF was not published to USB.' }
    if ($published -ne (Join-Path $layout.ReportRoot 'CASE-TEST-QC-Certificate.pdf')) { throw 'Published PDF path is not stable.' }

    $fakeRun=[pscustomobject]@{
        AssetId='CASE-TEST';CompletedAt='2026-01-01T12:00:00Z';OverallStatus='PASS'
        Physical=[pscustomobject]@{Seal1='CASE-TEST';CaseModel='GREEN AVA+';CpuAtpo='M6M71N2102883';Cooler='DeepCool AG400 PLUS';PsuModel='GREEN GP700A-GED V3.1';PsuSerial='PSU001'}
        Hardware=[pscustomobject]@{
            Motherboard=[pscustomobject]@{Model='TUF GAMING B760-PLUS WIFI';SerialNumber='MB001'}
            CPU=[pscustomobject]@{Model='Intel Core i7-14700K'}
            MemoryTotalGB=16
            Memory=@([pscustomobject]@{PartNumber='RAM-PART';SerialNumber='RAM001'})
            Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';SerialNumber='SSD001';BusType='NVMe'})
            BIOS=[pscustomobject]@{Version='1836'}
            Graphics=@([pscustomobject]@{Name='Intel UHD Graphics'})
            SystemUUID='UUID001'
        }
        Profile=[pscustomobject]@{Expected=[pscustomobject]@{StorageModelRegex='990 PRO'}}
        Security=[pscustomobject]@{HardwareIdentitySha256='HWID';Sha256='MANIFEST'}
    }
    $register=Update-SitecFleetRegister -ArchiveRoot $archive -Run $fakeRun -CertificatePath $published
    if (-not (Test-Path -LiteralPath $register)) { throw 'Excel-compatible Fleet-Register.csv was not created.' }
    $row=Import-Csv -LiteralPath $register | Select-Object -First 1
    if ($row.AssetId -ne 'CASE-TEST' -or $row.CpuAtpo -ne 'M6M71N2102883' -or $row.HardwareIdentitySha256 -ne 'HWID') { throw 'Fleet register contents are incomplete.' }

    Remove-SitecLocalQcResidue -WorkingRoot $work
    if (Test-Path -LiteralPath $work) { throw 'Temporary local QC workspace was not removed.' }

    $start=Get-Content -LiteralPath (Join-Path $root 'Start-SitecQC.ps1') -Raw -Encoding UTF8
    if ($start -notmatch 'Get-SitecEvidenceArchiveRoot') { throw 'GUI does not auto-detect the removable evidence archive.' }
    if ($start -notmatch 'New-SitecWorkingRoot') { throw 'GUI does not use a disposable temp workspace.' }
    if ($start -notmatch '-ArchiveRoot') { throw 'GUI does not pass the USB archive to the worker.' }

    $launcher=Get-Content -LiteralPath (Join-Path $root 'launcher\Program.cs') -Raw -Encoding UTF8
    if ($launcher -match 'CommonApplicationData') { throw 'Launcher still extracts persistent payload under ProgramData.' }
    if ($launcher -notmatch 'Path.GetTempPath') { throw 'Launcher does not use a temporary payload folder.' }
    if ($launcher -notmatch 'WaitForExit') { throw 'Launcher cannot clean its temporary payload after the UI exits.' }

    Write-Host 'USB-only archive and zero-persistent-local-state tests passed.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
