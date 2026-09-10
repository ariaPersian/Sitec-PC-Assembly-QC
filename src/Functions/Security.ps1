function Get-SitecSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function ConvertTo-SitecIdentityValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    (([string]$Value).Trim().ToUpperInvariant() -replace '\s+','')
}

function New-SitecHardwareIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $h=$Manifest.Hardware
    $p=$Manifest.Physical
    $profile=$Manifest.Profile
    $lines=@('SCHEMA=SITEC-HWID-V1')

    $stable=@(
        [pscustomobject]@{Name='ASSET';Value=$Manifest.AssetId},
        [pscustomobject]@{Name='SYSTEM_UUID';Value=$h.SystemUUID},
        [pscustomobject]@{Name='MOTHERBOARD_SERIAL';Value=$h.Motherboard.SerialNumber},
        [pscustomobject]@{Name='CPU_ATPO';Value=$p.CpuAtpo},
        [pscustomobject]@{Name='PSU_SERIAL';Value=$p.PsuSerial},
        [pscustomobject]@{Name='SEAL1';Value=$p.Seal1},
        [pscustomobject]@{Name='SEAL2';Value=$p.Seal2}
    )
    foreach ($item in $stable) {
        $value=ConvertTo-SitecIdentityValue $item.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) { $lines += ($item.Name+'='+$value) }
    }

    $ramSerials=@($h.Memory | ForEach-Object { ConvertTo-SitecIdentityValue $_.SerialNumber } | Where-Object { $_ } | Sort-Object)
    foreach ($serial in $ramSerials) { $lines += ('RAM_SERIAL='+$serial) }

    $identityStorage=@(Get-SitecIdentityStorage -Hardware $h -Profile $profile)
    $storageSerials=@($identityStorage | ForEach-Object { ConvertTo-SitecIdentityValue $_.SerialNumber } | Where-Object { $_ } | Sort-Object)
    foreach ($serial in $storageSerials) { $lines += ('STORAGE_SERIAL='+$serial) }

    $canonical=$lines -join "`n"
    $encoding=New-Object System.Text.UTF8Encoding($false)
    $bytes=$encoding.GetBytes($canonical)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') }
    finally { $sha.Dispose() }

    [pscustomobject]@{
        Schema='SITEC-HWID-V1'
        Sha256=$hash
        CanonicalText=$canonical
        RamSerials=$ramSerials
        StorageSerials=$storageSerials
    }
}

function Protect-SitecManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)]$Context)

    $hash=Get-SitecSha256 -Path $ManifestPath
    $shaPath=[IO.Path]::ChangeExtension($ManifestPath,'.sha256')
    Set-Content -LiteralPath $shaPath -Value "$hash  $([IO.Path]::GetFileName($ManifestPath))" -Encoding ASCII

    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $identity=New-SitecHardwareIdentity -Manifest $manifest
    $runPath=Split-Path -Parent $ManifestPath
    $identityTextPath=Join-Path $runPath 'hardware-identity.txt'
    $identityShaPath=Join-Path $runPath 'hardware-identity.sha256'
    Set-Content -LiteralPath $identityTextPath -Value $identity.CanonicalText -Encoding ASCII
    Set-Content -LiteralPath $identityShaPath -Value ($identity.Sha256+'  hardware-identity.txt') -Encoding ASCII

    $result=[ordered]@{
        Sha256=$hash
        HardwareIdentitySha256=$identity.Sha256
        HardwareIdentitySchema=$identity.Schema
        Signed=$false
        SignaturePath=$null
        CertificatePath=$null
        Thumbprint=$null
    }

    $thumb=[string]$Context.Settings.Security.SigningCertificateThumbprint
    if ([string]::IsNullOrWhiteSpace($thumb)) { return [pscustomobject]$result }

    $thumb=($thumb -replace '\s','').ToUpperInvariant()
    $cert=Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $thumb -and $_.HasPrivateKey } | Select-Object -First 1
    if (-not $cert) {
        if ($Context.Settings.Security.RequireDigitalSignature) { throw "Signing certificate $thumb with private key was not found." }
        return [pscustomobject]$result
    }

    $bytes=[IO.File]::ReadAllBytes($ManifestPath)
    $rsa=[System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    try {
        $sig=$rsa.SignData($bytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
        if ($rsa) { $rsa.Dispose() }
    }
    $sigPath=$ManifestPath+'.sig'
    [IO.File]::WriteAllText($sigPath,[Convert]::ToBase64String($sig),[Text.Encoding]::ASCII)
    $cerPath=$ManifestPath+'.cer'
    [IO.File]::WriteAllBytes($cerPath,$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))

    $result.Signed=$true
    $result.SignaturePath=$sigPath
    $result.CertificatePath=$cerPath
    $result.Thumbprint=$cert.Thumbprint
    [pscustomobject]$result
}

function Write-SitecEvidenceHashes {
    param([Parameter(Mandatory)][string]$RunPath)

    # The customer certificate contains both hashes:
    # - Hardware Identity SHA-256: stable across reruns while unique parts stay the same.
    # - Manifest SHA-256: protects the exact evidence document for this run.
    $identityShaPath=Join-Path $RunPath 'hardware-identity.sha256'
    $htmlPath=Join-Path $RunPath 'QC-Certificate.html'
    if ((Test-Path -LiteralPath $identityShaPath) -and (Test-Path -LiteralPath $htmlPath)) {
        $identityLine=(Get-Content -LiteralPath $identityShaPath -TotalCount 1 -ErrorAction SilentlyContinue)
        $identityHash=([string]$identityLine -split '\s+')[0]
        if (-not [string]::IsNullOrWhiteSpace($identityHash)) {
            $html=Get-Content -LiteralPath $htmlPath -Raw
            if ($html -notmatch 'Hardware Identity SHA-256') {
                $html=$html.Replace('Manifest SHA-256:',('Hardware Identity SHA-256: '+$identityHash+'<br>Manifest SHA-256:'))
                Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
                $pdfPath=Join-Path $RunPath 'QC-Certificate.pdf'
                if (Test-Path -LiteralPath $pdfPath) {
                    Remove-Item -LiteralPath $pdfPath -Force -ErrorAction SilentlyContinue
                    try { [void](Convert-SitecHtmlToPdf -HtmlPath $htmlPath -PdfPath $pdfPath) } catch {}
                }
            }
        }
    }

    $hashFile=Join-Path $RunPath 'hashes.sha256'
    $lines=@()
    Get-ChildItem -LiteralPath $RunPath -File -Recurse |
        Where-Object { $_.FullName -ne $hashFile -and $_.Extension -notin '.sig','.cer' } |
        Sort-Object FullName |
        ForEach-Object {
            $relative=$_.FullName.Substring($RunPath.Length).TrimStart('\')
            $lines += "$(Get-SitecSha256 $_.FullName)  $relative"
        }
    Set-Content -LiteralPath $hashFile -Value $lines -Encoding ASCII
    $hashFile
}
