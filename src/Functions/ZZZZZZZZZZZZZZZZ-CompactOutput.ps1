function Get-SitecInternalDataRoot {
    Join-Path $env:ProgramData 'SitecQC\Data'
}

function Get-SitecSupportRoot {
    Join-Path $env:ProgramData 'SitecQC\Support'
}

function Get-SitecPublishedReportRoot {
    param([Parameter(Mandatory)][string]$PublicRoot)
    Join-Path $PublicRoot 'Reports'
}

function Get-SitecPublishedCertificatePath {
    param([Parameter(Mandatory)][string]$PublicRoot,[Parameter(Mandatory)][string]$AssetId)
    Join-Path (Get-SitecPublishedReportRoot -PublicRoot $PublicRoot) ("{0}-QC-Certificate.pdf" -f $AssetId)
}

function Initialize-SitecCompactOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PublicRoot,
        [string]$InternalRoot=''
    )
    if ([string]::IsNullOrWhiteSpace($InternalRoot)) { $InternalRoot=Get-SitecInternalDataRoot }

    $reportRoot=Get-SitecPublishedReportRoot -PublicRoot $PublicRoot
    New-Item -ItemType Directory -Path $PublicRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $InternalRoot -Force | Out-Null

    # One-time migration from the legacy verbose C:\SitecQC-Data layout. The final PDF stays
    # user-visible; machine state required for duplicate detection and future verification is
    # retained under ProgramData instead of cluttering the delivery folder.
    foreach ($name in @('fleet-serial-index.csv','fleet-runs.csv')) {
        $source=Join-Path $PublicRoot $name
        $destination=Join-Path $InternalRoot $name
        if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }

    $legacyAssets=Join-Path $PublicRoot 'Assets'
    if (Test-Path -LiteralPath $legacyAssets) {
        foreach ($assetDir in @(Get-ChildItem -LiteralPath $legacyAssets -Directory -ErrorAction SilentlyContinue)) {
            $assetId=$assetDir.Name
            $legacyBaseline=Join-Path $assetDir.FullName 'Baseline'
            if (Test-Path -LiteralPath $legacyBaseline) {
                $targetBaseline=Join-Path $InternalRoot ("Assets\{0}\Baseline" -f $assetId)
                if (-not (Test-Path -LiteralPath $targetBaseline)) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $targetBaseline) -Force | Out-Null
                    Copy-Item -LiteralPath $legacyBaseline -Destination $targetBaseline -Recurse -Force
                }
            }

            $latestPdf=Get-ChildItem -LiteralPath (Join-Path $assetDir.FullName 'Runs') -Filter 'QC-Certificate.pdf' -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestPdf) {
                Copy-Item -LiteralPath $latestPdf.FullName -Destination (Get-SitecPublishedCertificatePath -PublicRoot $PublicRoot -AssetId $assetId) -Force
            }
        }
        Remove-Item -LiteralPath $legacyAssets -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($name in @('fleet-serial-index.csv','fleet-runs.csv','.fleet-index.lock')) {
        Remove-Item -LiteralPath (Join-Path $PublicRoot $name) -Force -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{PublicRoot=$PublicRoot;ReportRoot=$reportRoot;InternalRoot=$InternalRoot}
}

function Publish-SitecCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PublicRoot,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$SourcePdf
    )
    if (-not (Test-Path -LiteralPath $SourcePdf)) { return $null }
    $reportRoot=Get-SitecPublishedReportRoot -PublicRoot $PublicRoot
    New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
    $destination=Get-SitecPublishedCertificatePath -PublicRoot $PublicRoot -AssetId $AssetId
    Copy-Item -LiteralPath $SourcePdf -Destination $destination -Force
    $destination
}

function Save-SitecSupportBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$RunPath
    )
    if (-not (Test-Path -LiteralPath $RunPath)) { return $null }
    $supportRoot=Get-SitecSupportRoot
    New-Item -ItemType Directory -Path $supportRoot -Force | Out-Null
    $zip=Join-Path $supportRoot ("{0}-LastFailure.zip" -f $AssetId)
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $RunPath '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $zip
}

function Remove-SitecCompletedRuns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InternalRoot,
        [Parameter(Mandatory)][string]$AssetId
    )
    $runs=Join-Path $InternalRoot ("Assets\{0}\Runs" -f $AssetId)
    if (Test-Path -LiteralPath $runs) {
        Remove-Item -LiteralPath $runs -Recurse -Force -ErrorAction SilentlyContinue
    }
}
