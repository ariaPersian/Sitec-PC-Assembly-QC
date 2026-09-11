# Final evidence-integrity layer.
# Loaded after Security.ps1 so these definitions replace the earlier implementation.
# Goals:
# 1) hardware-identity.txt is written with the exact UTF-8/LF bytes that are hashed;
# 2) every production run can be signed automatically without operator input;
# 3) ephemeral self-signed private keys are deleted immediately after signing;
# 4) both manifest and hardware identity signatures are verified before the run continues.

function Write-SitecExactUtf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    $enc=New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllBytes($Path,$enc.GetBytes($Text))
}

function Test-SitecEvidenceSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$SignaturePath,
        [Parameter(Mandatory)][string]$CertificatePath
    )
    if (-not (Test-Path -LiteralPath $DataPath) -or -not (Test-Path -LiteralPath $SignaturePath) -or -not (Test-Path -LiteralPath $CertificatePath)) { return $false }
    try {
        $cert=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
        $rsa=[System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        try {
            $data=[IO.File]::ReadAllBytes($DataPath)
            $sig=[Convert]::FromBase64String(([IO.File]::ReadAllText($SignaturePath,[Text.Encoding]::ASCII)).Trim())
            return $rsa.VerifyData($data,$sig,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } finally { if ($rsa) { $rsa.Dispose() }; if ($cert) { $cert.Dispose() } }
    } catch { return $false }
}

function New-SitecEphemeralEvidenceCertificate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)]$Context)
    if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) { throw 'New-SelfSignedCertificate is unavailable; automatic evidence signing cannot continue.' }
    $bits=3072
    if ($Context.Settings.Security.PSObject.Properties['EphemeralKeyLength']) { $bits=[math]::Max(2048,[int]$Context.Settings.Security.EphemeralKeyLength) }
    $asset=([string]$Manifest.AssetId -replace '[^A-Za-z0-9._-]','_')
    $run=([string]$Manifest.RunId -replace '[^A-Za-z0-9._-]','_')
    $subject="CN=SITEC QC Evidence $asset $run"
    $params=@{
        Type='Custom'
        Subject=$subject
        KeyUsage='DigitalSignature'
        KeyAlgorithm='RSA'
        KeyLength=$bits
        HashAlgorithm='SHA256'
        KeyExportPolicy='NonExportable'
        CertStoreLocation='Cert:\CurrentUser\My'
        NotAfter=(Get-Date).AddYears(10)
        FriendlyName='SITEC QC one-time evidence signer'
    }
    New-SelfSignedCertificate @params
}

function Protect-SitecManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)]$Context)

    $manifestHash=Get-SitecSha256 -Path $ManifestPath
    $manifestShaPath=[IO.Path]::ChangeExtension($ManifestPath,'.sha256')
    Set-Content -LiteralPath $manifestShaPath -Value "$manifestHash  $([IO.Path]::GetFileName($ManifestPath))" -Encoding ASCII

    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $identity=New-SitecHardwareIdentity -Manifest $manifest
    $runPath=Split-Path -Parent $ManifestPath
    $identityTextPath=Join-Path $runPath 'hardware-identity.txt'
    $identityShaPath=Join-Path $runPath 'hardware-identity.sha256'

    # Write EXACTLY the canonical bytes that New-SitecHardwareIdentity hashed: UTF-8, no BOM,
    # LF separators and no implicit trailing CR/LF. This makes Get-FileHash reproducible.
    Write-SitecExactUtf8NoBom -Path $identityTextPath -Text ([string]$identity.CanonicalText)
    $identityFileHash=Get-SitecSha256 -Path $identityTextPath
    if ($identityFileHash -ne [string]$identity.Sha256) {
        throw "Hardware identity byte/hash mismatch. Canonical=$($identity.Sha256), File=$identityFileHash"
    }
    Set-Content -LiteralPath $identityShaPath -Value ($identityFileHash+'  hardware-identity.txt') -Encoding ASCII

    $result=[ordered]@{
        Sha256=$manifestHash
        HardwareIdentitySha256=$identityFileHash
        HardwareIdentitySchema=$identity.Schema
        Signed=$false
        SignatureAlgorithm='RSA-PKCS1-SHA256'
        SignatureMode='Unsigned'
        SignaturePath=$null
        HardwareIdentitySignaturePath=$null
        CertificatePath=$null
        Thumbprint=$null
        SigningSubject=$null
        ManifestSignatureVerified=$false
        HardwareIdentitySignatureVerified=$false
        PrivateKeyRetained=$false
    }

    $security=$Context.Settings.Security
    $require=$false
    if ($security.PSObject.Properties['RequireDigitalSignature']) { $require=[bool]$security.RequireDigitalSignature }
    $auto=$false
    if ($security.PSObject.Properties['AutoCreateEphemeralCertificate']) { $auto=[bool]$security.AutoCreateEphemeralCertificate }

    $cert=$null;$ephemeral=$false
    $configuredThumb=''
    if ($security.PSObject.Properties['SigningCertificateThumbprint']) { $configuredThumb=([string]$security.SigningCertificateThumbprint -replace '\s','').ToUpperInvariant() }
    try {
        if (-not [string]::IsNullOrWhiteSpace($configuredThumb)) {
            $cert=Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $configuredThumb -and $_.HasPrivateKey } | Select-Object -First 1
            if ($cert) { $result.SignatureMode='ConfiguredCertificate';$result.PrivateKeyRetained=$true }
        } elseif ($auto) {
            $cert=New-SitecEphemeralEvidenceCertificate -Manifest $manifest -Context $Context
            $ephemeral=$true
            $result.SignatureMode='EphemeralSelfSigned'
            $result.PrivateKeyRetained=$false
        }

        if (-not $cert) {
            if ($require) { throw 'A digital signature is required, but no usable signing certificate could be created or found.' }
            return [pscustomobject]$result
        }

        $manifestSigPath=$ManifestPath+'.sig'
        $identitySigPath=$identityTextPath+'.sig'
        $cerPath=Join-Path $runPath 'evidence-signing.cer'
        [IO.File]::WriteAllBytes($cerPath,$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))

        $rsa=[System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if (-not $rsa) { throw 'The evidence signing certificate does not expose an RSA private key.' }
        try {
            $manifestSig=$rsa.SignData([IO.File]::ReadAllBytes($ManifestPath),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $identitySig=$rsa.SignData([IO.File]::ReadAllBytes($identityTextPath),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } finally { $rsa.Dispose() }
        [IO.File]::WriteAllText($manifestSigPath,[Convert]::ToBase64String($manifestSig),[Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($identitySigPath,[Convert]::ToBase64String($identitySig),[Text.Encoding]::ASCII)

        $manifestVerified=Test-SitecEvidenceSignature -DataPath $ManifestPath -SignaturePath $manifestSigPath -CertificatePath $cerPath
        $identityVerified=Test-SitecEvidenceSignature -DataPath $identityTextPath -SignaturePath $identitySigPath -CertificatePath $cerPath
        if (-not $manifestVerified -or -not $identityVerified) { throw 'Immediate RSA/SHA-256 evidence signature verification failed.' }

        $result.Signed=$true
        $result.SignaturePath=$manifestSigPath
        $result.HardwareIdentitySignaturePath=$identitySigPath
        $result.CertificatePath=$cerPath
        $result.Thumbprint=$cert.Thumbprint
        $result.SigningSubject=$cert.Subject
        $result.ManifestSignatureVerified=$manifestVerified
        $result.HardwareIdentitySignatureVerified=$identityVerified

        $summary=[ordered]@{
            Schema='SITEC-EVIDENCE-SIGNATURE-V1'
            AssetId=$manifest.AssetId
            RunId=$manifest.RunId
            SignatureAlgorithm=$result.SignatureAlgorithm
            SignatureMode=$result.SignatureMode
            CertificateThumbprint=$result.Thumbprint
            CertificateSubject=$result.SigningSubject
            ManifestSha256=$manifestHash
            HardwareIdentitySha256=$identityFileHash
            ManifestSignatureVerified=$manifestVerified
            HardwareIdentitySignatureVerified=$identityVerified
            PrivateKeyRetained=$result.PrivateKeyRetained
            VerifiedAt=(Get-Date).ToString('o')
        }
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runPath 'signature-verification.json') -Encoding UTF8
        return [pscustomobject]$result
    }
    finally {
        # One-time automatic signer: destroy the private key immediately after evidence is signed.
        # The exported public certificate remains with the evidence and is sufficient to verify it later.
        if ($ephemeral -and $cert) {
            try { Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$cert.Thumbprint) -Force -ErrorAction SilentlyContinue } catch {}
            try { $cert.Dispose() } catch {}
        }
    }
}
