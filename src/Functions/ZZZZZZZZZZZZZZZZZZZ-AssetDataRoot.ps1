function Get-SitecAssetDataRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$')][string]$AssetId,
        [string]$BaseDataRoot='C:\SitecQC-Data'
    )

    $asset=$AssetId.Trim()
    if ($asset -match '(\d+)$') {
        # Production asset labels such as CASE-001 or PC-001 map to the same
        # numeric suffix the operator sees on the physical case label.
        $suffix=$Matches[1]
    } else {
        # Keep a deterministic, filesystem-safe fallback for non-numeric IDs.
        $suffix=($asset -replace '[^A-Za-z0-9._-]','-')
    }

    if ([string]::IsNullOrWhiteSpace($BaseDataRoot)) { $BaseDataRoot='C:\SitecQC-Data' }
    $base=[IO.Path]::GetFullPath($BaseDataRoot)
    $parent=Split-Path -Parent $base
    $leaf=Split-Path -Leaf $base
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent=[IO.Path]::GetPathRoot($base) }
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf='SitecQC-Data' }

    [IO.Path]::GetFullPath((Join-Path $parent ("{0}-{1}" -f $leaf,$suffix)))
}

function New-SitecWorkingRoot {
    [CmdletBinding()]
    param(
        [string]$AssetId='',
        [string]$BaseDataRoot='C:\SitecQC-Data'
    )

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        # Backward-compatible/test fallback when no asset identity is available.
        $path=Join-Path $env:TEMP ('SitecQC-Run-'+[guid]::NewGuid().ToString('N'))
    } else {
        $path=Get-SitecAssetDataRoot -AssetId $AssetId -BaseDataRoot $BaseDataRoot
        # A production run owns this scratch root. Remove stale residue from an
        # interrupted/older run before beginning a new run for the same asset.
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }

    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}
