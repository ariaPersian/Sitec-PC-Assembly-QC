function Get-SitecBaselineRoot {
    [CmdletBinding()]
    param([string]$LauncherDir='')

    if (-not [string]::IsNullOrWhiteSpace($env:SITECQC_BASELINE_ROOT)) {
        return ([IO.Path]::GetFullPath([string]$env:SITECQC_BASELINE_ROOT))
    }
    if (-not [string]::IsNullOrWhiteSpace($LauncherDir)) {
        return ([IO.Path]::GetFullPath($LauncherDir))
    }
    'C:\BaselineQC'
}

function Get-SitecPublishedReportRoot {
    param([Parameter(Mandatory)][Alias('PublicRoot','ArchiveRoot')][string]$BaselineRoot)
    Join-Path $BaselineRoot 'Output'
}

function Get-SitecPublishedCertificatePath {
    param([Parameter(Mandatory)][Alias('PublicRoot','ArchiveRoot')][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ("{0}-QC-Certificate.pdf" -f $AssetId)
}

function Get-SitecPublishedBaselinePath {
    param([Parameter(Mandatory)][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ("{0}-Baseline.json" -f $AssetId)
}

function Get-SitecFailureBundlePath {
    param([Parameter(Mandatory)][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot) ("{0}-LastFailure.zip" -f $AssetId)
}

function Initialize-SitecBaselineLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaselineRoot)

    $output=Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot
    New-Item -ItemType Directory -Path $BaselineRoot,$output -Force | Out-Null

    # v3.8 stores no durable QC database under ProgramData. Remove only known
    # SitecQC implementation folders from older builds; the operator-visible
    # C:\BaselineQC folder is preserved.
    foreach ($path in @(
        (Join-Path $env:ProgramData 'SitecQC\Data'),
        (Join-Path $env:ProgramData 'SitecQC\Support'),
        (Join-Path $env:ProgramData 'SitecQC\App')
    )) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    try {
        $pd=Join-Path $env:ProgramData 'SitecQC'
        Remove-Item -LiteralPath (Join-Path $pd 'asset-id.txt') -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $pd) -and @(Get-ChildItem -LiteralPath $pd -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $pd -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    [pscustomobject]@{BaselineRoot=$BaselineRoot;OutputRoot=$output}
}

# Backward-compatible name for source/tests from older releases.
function Initialize-SitecCompactOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('PublicRoot','ArchiveRoot')][string]$BaselineRoot,[string]$InternalRoot='')
    Initialize-SitecBaselineLayout -BaselineRoot $BaselineRoot
}

function New-SitecWorkingRoot {
    $path=Join-Path $env:TEMP ('SitecQC-Run-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}

# v3.8 intentionally has no persistent fleet state on the tested PC. These
# compatibility shims leave the temporary working root empty.
function Seed-SitecWorkingState {
    [CmdletBinding()]
    param([string]$ArchiveRoot,[Parameter(Mandatory)][string]$WorkingRoot)
    New-Item -ItemType Directory -Path $WorkingRoot -Force | Out-Null
}
function Sync-SitecWorkingState {
    [CmdletBinding()]
    param([string]$ArchiveRoot,[Parameter(Mandatory)][string]$WorkingRoot,[Parameter(Mandatory)][string]$AssetId)
}

function Publish-SitecCertificate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('PublicRoot','ArchiveRoot')][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId,[Parameter(Mandatory)][string]$SourcePdf)
    if (-not (Test-Path -LiteralPath $SourcePdf)) { return $null }
    $output=Get-SitecPublishedReportRoot -BaselineRoot $BaselineRoot
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $destination=Get-SitecPublishedCertificatePath -BaselineRoot $BaselineRoot -AssetId $AssetId
    Copy-Item -LiteralPath $SourcePdf -Destination $destination -Force
    $destination
}

function Publish-SitecBaselineJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselineRoot,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$CertificatePath=''
    )
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }
    $run=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $storage=@(Get-SitecIdentityStorage -Hardware $run.Hardware -Profile $run.Profile)

    $baseline=[ordered]@{
        Schema='SITEC-BASELINE-V1'
        AssetId=[string]$run.AssetId
        TamperSeal=[string]$run.Physical.Seal1
        CreatedAt=[string]$run.CompletedAt
        OverallStatus=[string]$run.OverallStatus
        Profile=[ordered]@{
            Id=[string]$run.Profile.ProfileId
            Version=[string]$run.Profile.ProfileVersion
        }
        Case=[ordered]@{Model=[string]$run.Physical.CaseModel}
        PowerSupply=[ordered]@{Model=[string]$run.Physical.PsuModel;Serial=[string]$run.Physical.PsuSerial}
        CpuCooler=[ordered]@{Model=[string]$run.Physical.Cooler}
        CPU=[ordered]@{
            Model=[string]$run.Hardware.CPU.Model
            Cores=$run.Hardware.CPU.Cores
            LogicalProcessors=$run.Hardware.CPU.LogicalProcessors
            Atpo=[string]$run.Physical.CpuAtpo
        }
        Motherboard=[ordered]@{
            Manufacturer=[string]$run.Hardware.Motherboard.Manufacturer
            Model=[string]$run.Hardware.Motherboard.Model
            Serial=[string]$run.Hardware.Motherboard.SerialNumber
        }
        SystemUUID=[string]$run.Hardware.SystemUUID
        BIOS=[ordered]@{Version=[string]$run.Hardware.BIOS.Version;ReleaseDate=[string]$run.Hardware.BIOS.ReleaseDate}
        Memory=@($run.Hardware.Memory | ForEach-Object {
            [ordered]@{Slot=[string]$_.Slot;Manufacturer=[string]$_.Manufacturer;PartNumber=[string]$_.PartNumber;Serial=[string]$_.SerialNumber;CapacityGB=$_.CapacityGB;ConfiguredSpeedMHz=$_.ConfiguredSpeedMHz}
        })
        Storage=@($storage | ForEach-Object {
            [ordered]@{Model=[string]$_.Model;Serial=[string]$_.SerialNumber;Firmware=[string]$_.FirmwareVersion;SizeGB=$_.SizeGB;BusType=[string]$_.BusType}
        })
        Graphics=@($run.Hardware.Graphics | ForEach-Object { [string]$_.Name })
        HardwareIdentity=[ordered]@{
            Schema=[string]$run.Security.HardwareIdentitySchema
            Sha256=[string]$run.Security.HardwareIdentitySha256
        }
        ManifestSha256=[string]$run.Security.Sha256
        CertificateFile=$(if($CertificatePath){[IO.Path]::GetFileName($CertificatePath)}else{''})
    }

    $destination=Get-SitecPublishedBaselinePath -BaselineRoot $BaselineRoot -AssetId $AssetId
    $baseline | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $destination -Encoding UTF8
    $destination
}

function Save-SitecSupportBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('ArchiveRoot')][string]$BaselineRoot,[Parameter(Mandatory)][string]$AssetId,[Parameter(Mandatory)][string]$RunPath)
    if (-not (Test-Path -LiteralPath $RunPath)) { return $null }
    $zip=Get-SitecFailureBundlePath -BaselineRoot $BaselineRoot -AssetId $AssetId
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $RunPath '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $zip
}

function Remove-SitecLocalQcResidue {
    [CmdletBinding()]
    param([string]$WorkingRoot='')
    if ($WorkingRoot -and (Test-Path -LiteralPath $WorkingRoot)) { Remove-Item -LiteralPath $WorkingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($path in @(
        (Join-Path $env:ProgramData 'SitecQC\Data'),
        (Join-Path $env:ProgramData 'SitecQC\Support'),
        (Join-Path $env:ProgramData 'SitecQC\App')
    )) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-SitecCompletedRuns {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('InternalRoot')][string]$WorkingRoot,[Parameter(Mandatory)][string]$AssetId)
    Remove-SitecLocalQcResidue -WorkingRoot $WorkingRoot
}
