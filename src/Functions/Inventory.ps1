function Test-SitecUsefulIdentifier {
    param($Value)
    $s=([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }

    $upper=$s.ToUpperInvariant()
    $bad=@(
        'NONE','N/A','NA','DEFAULT STRING','DEFAULT',
        'TO BE FILLED BY O.E.M.','TO BE FILLED BY OEM',
        'SYSTEM SERIAL NUMBER','UNKNOWN','0','00000000','123456789'
    )
    if ($bad -contains $upper) { return $false }

    # Reject common empty/placeholder SMBIOS UUID/serial patterns such as
    # 0000... and FFFF..., regardless of dashes/braces/spaces.
    $compact=$upper -replace '[^A-Z0-9]',''
    if ($compact.Length -ge 8 -and ($compact -match '^0+$' -or $compact -match '^F+$')) { return $false }

    return $true
}

function ConvertTo-SitecAssetToken {
    param([string]$Value)
    $s=($Value.ToUpperInvariant() -replace '[^A-Z0-9_-]','')
    if ($s.Length -gt 24) { $s=$s.Substring($s.Length-24) }
    $s
}

function Get-SitecAutoAssetId {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Hardware)

    $stateRoot=Join-Path $env:ProgramData 'SitecQC'
    $statePath=Join-Path $stateRoot 'asset-id.txt'
    try {
        if (Test-Path -LiteralPath $statePath) {
            $saved=(Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop).Trim()
            if ($saved -match '^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$') { return $saved }
        }
    } catch {}

    $id=$null
    if ($Hardware.PSObject.Properties['SystemEnclosure'] -and (Test-SitecUsefulIdentifier $Hardware.SystemEnclosure.SMBIOSAssetTag)) {
        $token=ConvertTo-SitecAssetToken ([string]$Hardware.SystemEnclosure.SMBIOSAssetTag)
        if ($token) { $id='PC-' + $token }
    }
    if (-not $id -and (Test-SitecUsefulIdentifier $Hardware.SystemUUID)) {
        $token=ConvertTo-SitecAssetToken (([string]$Hardware.SystemUUID) -replace '-','')
        if ($token.Length -gt 12) { $token=$token.Substring($token.Length-12) }
        if ($token) { $id='PC-' + $token }
    }
    if (-not $id -and (Test-SitecUsefulIdentifier $Hardware.Motherboard.SerialNumber)) {
        $token=ConvertTo-SitecAssetToken ([string]$Hardware.Motherboard.SerialNumber)
        if ($token.Length -gt 12) { $token=$token.Substring($token.Length-12) }
        if ($token) { $id='PC-' + $token }
    }
    if (-not $id) { $id='PC-' + [guid]::NewGuid().ToString('N').Substring(0,12).ToUpperInvariant() }

    try {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        Set-Content -LiteralPath $statePath -Value $id -Encoding ASCII
    } catch {}
    $id
}

function Get-SitecSerialSet {
    param($Hardware,$Physical)
    $rows=@()
    if ($Hardware.Motherboard.SerialNumber) { $rows += [pscustomobject]@{Type='Motherboard';Serial=[string]$Hardware.Motherboard.SerialNumber} }
    foreach ($m in @($Hardware.Memory)) { if ($m.SerialNumber) { $rows += [pscustomobject]@{Type='RAM';Serial=[string]$m.SerialNumber} } }
    foreach ($d in @($Hardware.Storage)) { if ($d.SerialNumber) { $rows += [pscustomobject]@{Type='Storage';Serial=[string]$d.SerialNumber} }
    if ($Physical.CpuAtpo) { $rows += [pscustomobject]@{Type='CPU-ATPO';Serial=[string]$Physical.CpuAtpo} }
    if ($Physical.PsuSerial) { $rows += [pscustomobject]@{Type='PSU';Serial=[string]$Physical.PsuSerial} }
    if ($Physical.Seal1) { $rows += [pscustomobject]@{Type='Seal';Serial=[string]$Physical.Seal1} }
    if ($Physical.Seal2) { $rows += [pscustomobject]@{Type='Seal';Serial=[string]$Physical.Seal2} }
    @($rows | ForEach-Object { $_.Serial=$_.Serial.Trim().ToUpperInvariant();$_ } | Where-Object { $_.Serial })
}

function Find-SitecDuplicateSerials {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)]$Hardware,
        [Parameter(Mandatory)]$Physical
    )
    $index=Join-Path $DataRoot 'fleet-serial-index.csv'
    if (-not (Test-Path $index)) { return @() }
    $existing=@(Import-Csv $index -ErrorAction SilentlyContinue)
    $dups=@()
    foreach ($s in @(Get-SitecSerialSet $Hardware $Physical)) {
        foreach ($hit in @($existing | Where-Object { $_.Type -eq $s.Type -and $_.Serial -eq $s.Serial -and $_.AssetId -ne $AssetId })) {
            $dups += [pscustomobject]@{Type=$s.Type;Serial=$s.Serial;ExistingAssetId=$hit.AssetId;ExistingRunId=$hit.RunId}
        }
    }
    $dups
}

function Update-SitecFleetIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)]$Run)
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    $serialIndex=Join-Path $DataRoot 'fleet-serial-index.csv'
    $runIndex=Join-Path $DataRoot 'fleet-runs.csv'
    $lockPath=Join-Path $DataRoot '.fleet-index.lock'
    $lock=$null
    for ($i=0;$i -lt 30;$i++) {
        try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $lock) { throw 'Could not acquire fleet index lock.' }
    try {
        $existing=@()
        if (Test-Path $serialIndex) { $existing=@(Import-Csv $serialIndex) }
        $existing=@($existing | Where-Object { $_.AssetId -ne $Run.AssetId })
        $new=@(Get-SitecSerialSet $Run.Hardware $Run.Physical | ForEach-Object {
            [pscustomobject]@{AssetId=$Run.AssetId;RunId=$Run.RunId;Type=$_.Type;Serial=$_.Serial;Timestamp=$Run.CompletedAt}
        })
        @($existing+$new) | Export-Csv $serialIndex -NoTypeInformation -Encoding UTF8

        $runs=@()
        if (Test-Path $runIndex) { $runs=@(Import-Csv $runIndex) }
        $runs=@($runs | Where-Object { $_.AssetId -ne $Run.AssetId })
        $runs += [pscustomobject]@{
            AssetId=$Run.AssetId
            RunId=$Run.RunId
            Timestamp=$Run.CompletedAt
            ProfileId=$Run.Profile.ProfileId
            OverallStatus=$Run.OverallStatus
            MotherboardSerial=$Run.Hardware.Motherboard.SerialNumber
            StorageSerials=(@($Run.Hardware.Storage | Select-Object -ExpandProperty SerialNumber) -join '|')
            RamSerials=(@($Run.Hardware.Memory | Select-Object -ExpandProperty SerialNumber) -join '|')
            CpuAtpo=$Run.Physical.CpuAtpo
            PsuSerial=$Run.Physical.PsuSerial
            ManifestSha256=$Run.Security.Sha256
        }
        $runs | Export-Csv $runIndex -NoTypeInformation -Encoding UTF8
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}
