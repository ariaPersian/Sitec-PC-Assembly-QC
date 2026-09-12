function Get-SitecEvidenceArchiveRoot {
    [CmdletBinding()]
    param([string]$LauncherDir='')

    if (-not [string]::IsNullOrWhiteSpace($env:SITECQC_ARCHIVE_ROOT)) {
        return ([IO.Path]::GetFullPath([string]$env:SITECQC_ARCHIVE_ROOT))
    }

    if (-not [string]::IsNullOrWhiteSpace($LauncherDir)) {
        try {
            $driveRoot=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($LauncherDir))
            if ($driveRoot) {
                $drive=New-Object IO.DriveInfo($driveRoot)
                if ($drive.IsReady -and $drive.DriveType -eq [IO.DriveType]::Removable) {
                    return (Join-Path $drive.RootDirectory.FullName 'SitecQC-Archive')
                }
            }
        } catch {}
    }

    $removable=@([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq [IO.DriveType]::Removable })
    $existing=@($removable | Where-Object { Test-Path -LiteralPath (Join-Path $_.RootDirectory.FullName 'SitecQC-Archive') })
    if ($existing.Count -eq 1) { return (Join-Path $existing[0].RootDirectory.FullName 'SitecQC-Archive') }
    if ($removable.Count -eq 1) { return (Join-Path $removable[0].RootDirectory.FullName 'SitecQC-Archive') }
    if ($removable.Count -eq 0) { throw 'No removable evidence USB drive was detected. Insert the SITEC archive flash drive and start SitecQC again.' }
    throw 'More than one removable drive is connected. Run SitecQC.exe from the archive flash drive so the evidence destination is unambiguous.'
}

function Get-SitecArchiveStateRoot {
    param([Parameter(Mandatory)][string]$ArchiveRoot)
    Join-Path $ArchiveRoot '.state'
}

function Get-SitecPublishedReportRoot {
    param([Parameter(Mandatory)][Alias('PublicRoot')][string]$ArchiveRoot)
    Join-Path $ArchiveRoot 'Reports'
}

function Get-SitecPublishedCertificatePath {
    param([Parameter(Mandatory)][Alias('PublicRoot')][string]$ArchiveRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -ArchiveRoot $ArchiveRoot) ("{0}-QC-Certificate.pdf" -f $AssetId)
}

function Get-SitecFailureRoot {
    param([Parameter(Mandatory)][string]$ArchiveRoot)
    Join-Path $ArchiveRoot 'Failures'
}

function Initialize-SitecPortableArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveRoot)

    $reports=Get-SitecPublishedReportRoot -ArchiveRoot $ArchiveRoot
    $state=Get-SitecArchiveStateRoot -ArchiveRoot $ArchiveRoot
    $failures=Get-SitecFailureRoot -ArchiveRoot $ArchiveRoot
    New-Item -ItemType Directory -Path $ArchiveRoot,$reports,$state,$failures -Force | Out-Null
    try { (Get-Item -LiteralPath $state).Attributes = (Get-Item -LiteralPath $state).Attributes -bor [IO.FileAttributes]::Hidden } catch {}

    # One-time migration from older releases. Durable evidence is copied to the USB archive first,
    # then local persistent QC folders are removed so the delivered PC does not retain evidence/state.
    $legacyRoots=@(
        'C:\SitecQC-Data',
        (Join-Path $env:ProgramData 'SitecQC\Data')
    ) | Select-Object -Unique

    foreach ($legacy in $legacyRoots) {
        if (-not (Test-Path -LiteralPath $legacy)) { continue }

        foreach ($pdf in @(Get-ChildItem -LiteralPath $legacy -Filter 'QC-Certificate.pdf' -Recurse -File -ErrorAction SilentlyContinue)) {
            $asset=$null
            if ($pdf.FullName -match '\\Assets\\([^\\]+)\\') { $asset=$Matches[1] }
            elseif ($pdf.BaseName -match '^(.+?)-QC-Certificate$') { $asset=$Matches[1] }
            if ($asset) { Copy-Item -LiteralPath $pdf.FullName -Destination (Get-SitecPublishedCertificatePath -ArchiveRoot $ArchiveRoot -AssetId $asset) -Force }
        }

        foreach ($name in @('fleet-serial-index.csv','fleet-runs.csv')) {
            $source=Join-Path $legacy $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $state $name) -Force }
        }

        $legacyAssets=Join-Path $legacy 'Assets'
        if (Test-Path -LiteralPath $legacyAssets) {
            foreach ($assetDir in @(Get-ChildItem -LiteralPath $legacyAssets -Directory -ErrorAction SilentlyContinue)) {
                $baseline=Join-Path $assetDir.FullName 'Baseline'
                if (Test-Path -LiteralPath $baseline) {
                    $target=Join-Path $state ("Assets\{0}\Baseline" -f $assetDir.Name)
                    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                    Copy-Item -LiteralPath $baseline -Destination $target -Recurse -Force
                }
            }
        }
    }

    $legacySupport=Join-Path $env:ProgramData 'SitecQC\Support'
    if (Test-Path -LiteralPath $legacySupport) {
        foreach ($zip in @(Get-ChildItem -LiteralPath $legacySupport -Filter '*-LastFailure.zip' -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $zip.FullName -Destination (Join-Path $failures $zip.Name) -Force
        }
    }

    foreach ($path in @('C:\SitecQC-Data',(Join-Path $env:ProgramData 'SitecQC\Data'),(Join-Path $env:ProgramData 'SitecQC\Support'),(Join-Path $env:ProgramData 'SitecQC\App'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $programDataRoot=Join-Path $env:ProgramData 'SitecQC'
    try {
        if ((Test-Path -LiteralPath $programDataRoot) -and @(Get-ChildItem -LiteralPath $programDataRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $programDataRoot -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    [pscustomobject]@{ArchiveRoot=$ArchiveRoot;ReportRoot=$reports;StateRoot=$state;FailureRoot=$failures;FleetRegister=(Join-Path $ArchiveRoot 'Fleet-Register.csv')}
}

# Backward-compatible name used by older tests/source tooling.
function Initialize-SitecCompactOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('PublicRoot')][string]$ArchiveRoot,[string]$InternalRoot='')
    Initialize-SitecPortableArchive -ArchiveRoot $ArchiveRoot
}

function New-SitecWorkingRoot {
    $path=Join-Path $env:TEMP ('SitecQC-Run-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}

function Seed-SitecWorkingState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveRoot,[Parameter(Mandatory)][string]$WorkingRoot)
    $state=Get-SitecArchiveStateRoot -ArchiveRoot $ArchiveRoot
    New-Item -ItemType Directory -Path $WorkingRoot -Force | Out-Null
    foreach ($name in @('fleet-serial-index.csv','fleet-runs.csv')) {
        $source=Join-Path $state $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $WorkingRoot $name) -Force }
    }
    $assets=Join-Path $state 'Assets'
    if (Test-Path -LiteralPath $assets) { Copy-Item -LiteralPath $assets -Destination (Join-Path $WorkingRoot 'Assets') -Recurse -Force }
}

function Sync-SitecWorkingState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveRoot,[Parameter(Mandatory)][string]$WorkingRoot,[Parameter(Mandatory)][string]$AssetId)
    $state=Get-SitecArchiveStateRoot -ArchiveRoot $ArchiveRoot
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    foreach ($name in @('fleet-serial-index.csv','fleet-runs.csv')) {
        $source=Join-Path $WorkingRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $state $name) -Force }
    }
    $baseline=Join-Path $WorkingRoot ("Assets\{0}\Baseline" -f $AssetId)
    if (Test-Path -LiteralPath $baseline) {
        $target=Join-Path $state ("Assets\{0}\Baseline" -f $AssetId)
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $baseline -Destination $target -Recurse -Force
    }
}

function Publish-SitecCertificate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('PublicRoot')][string]$ArchiveRoot,[Parameter(Mandatory)][string]$AssetId,[Parameter(Mandatory)][string]$SourcePdf)
    if (-not (Test-Path -LiteralPath $SourcePdf)) { return $null }
    $reportRoot=Get-SitecPublishedReportRoot -ArchiveRoot $ArchiveRoot
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    $destination=Get-SitecPublishedCertificatePath -ArchiveRoot $ArchiveRoot -AssetId $AssetId
    Copy-Item -LiteralPath $SourcePdf -Destination $destination -Force
    $destination
}

function Save-SitecSupportBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveRoot,[Parameter(Mandatory)][string]$AssetId,[Parameter(Mandatory)][string]$RunPath)
    if (-not (Test-Path -LiteralPath $RunPath)) { return $null }
    $root=Get-SitecFailureRoot -ArchiveRoot $ArchiveRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $zip=Join-Path $root ("{0}-LastFailure.zip" -f $AssetId)
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $RunPath '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $zip
}

function Update-SitecFleetRegister {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveRoot,[Parameter(Mandatory)]$Run,[Parameter(Mandatory)][string]$CertificatePath)

    $register=Join-Path $ArchiveRoot 'Fleet-Register.csv'
    $rows=@()
    if (Test-Path -LiteralPath $register) { $rows=@(Import-Csv -LiteralPath $register -ErrorAction SilentlyContinue) }
    $rows=@($rows | Where-Object { $_.AssetId -ne [string]$Run.AssetId })

    $ramParts=(@($Run.Hardware.Memory | ForEach-Object { ([string]$_.PartNumber).Trim() }) | Where-Object { $_ } | Sort-Object -Unique) -join '|'
    $ramSerials=(@($Run.Hardware.Memory | ForEach-Object { ([string]$_.SerialNumber).Trim() }) | Where-Object { $_ } | Sort-Object) -join '|'
    $storage=@(Get-SitecIdentityStorage -Hardware $Run.Hardware -Profile $Run.Profile)
    $storageModels=(@($storage | ForEach-Object { ([string]$_.Model).Trim() }) | Where-Object { $_ } | Sort-Object -Unique) -join '|'
    $storageSerials=(@($storage | ForEach-Object { ([string]$_.SerialNumber).Trim() }) | Where-Object { $_ } | Sort-Object) -join '|'
    $gpu=(@($Run.Hardware.Graphics | ForEach-Object { ([string]$_.Name).Trim() }) | Where-Object { $_ } | Sort-Object -Unique) -join '|'

    $rows += [pscustomobject][ordered]@{
        AssetId=[string]$Run.AssetId
        TamperSeal=[string]$Run.Physical.Seal1
        TestDate=[string]$Run.CompletedAt
        OverallStatus=[string]$Run.OverallStatus
        CaseModel=[string]$Run.Physical.CaseModel
        MotherboardModel=[string]$Run.Hardware.Motherboard.Model
        MotherboardSerial=[string]$Run.Hardware.Motherboard.SerialNumber
        CpuModel=[string]$Run.Hardware.CPU.Model
        CpuAtpo=[string]$Run.Physical.CpuAtpo
        CpuCooler=[string]$Run.Physical.Cooler
        PsuModel=[string]$Run.Physical.PsuModel
        PsuSerial=[string]$Run.Physical.PsuSerial
        MemoryGB=[string]$Run.Hardware.MemoryTotalGB
        RamPartNumbers=$ramParts
        RamSerials=$ramSerials
        StorageModels=$storageModels
        StorageSerials=$storageSerials
        BiosVersion=[string]$Run.Hardware.BIOS.Version
        Gpu=$gpu
        SystemUUID=[string]$Run.Hardware.SystemUUID
        HardwareIdentitySha256=[string]$Run.Security.HardwareIdentitySha256
        ManifestSha256=[string]$Run.Security.Sha256
        CertificateFile=[IO.Path]::GetFileName($CertificatePath)
    }
    $rows | Sort-Object AssetId | Export-Csv -LiteralPath $register -NoTypeInformation -Encoding UTF8
    $register
}

function Remove-SitecLocalQcResidue {
    [CmdletBinding()]
    param([string]$WorkingRoot='')
    if ($WorkingRoot -and (Test-Path -LiteralPath $WorkingRoot)) { Remove-Item -LiteralPath $WorkingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($path in @('C:\SitecQC-Data',(Join-Path $env:ProgramData 'SitecQC\Data'),(Join-Path $env:ProgramData 'SitecQC\Support'),(Join-Path $env:ProgramData 'SitecQC\App'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    try {
        $pd=Join-Path $env:ProgramData 'SitecQC'
        $assetState=Join-Path $pd 'asset-id.txt'
        Remove-Item -LiteralPath $assetState -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $pd) -and @(Get-ChildItem -LiteralPath $pd -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $pd -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# Older callers use this name; completed runs are now removed with the whole temporary working root.
function Remove-SitecCompletedRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('InternalRoot')][string]$WorkingRoot,[Parameter(Mandatory)][string]$AssetId)
    Remove-SitecLocalQcResidue -WorkingRoot $WorkingRoot
}
