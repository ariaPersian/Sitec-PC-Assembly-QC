$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\Sitec.QC.psm1') -Force

$temp=Join-Path $env:TEMP ('SitecQC-security-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $profile=Get-SitecProfile -Context ([pscustomobject]@{ProjectRoot=$repo;Settings=[pscustomobject]@{}}) -ProfileId 'B760-14700K-990PRO'
    $manifestObject=[pscustomobject]@{
        SchemaVersion='test'
        AssetId='CASE-SECURITY-TEST'
        RunId='CASE-SECURITY-TEST-20260911-000000'
        Profile=$profile
        Physical=[pscustomobject]@{
            PsuSerial='PSU-TEST-0001'
            CpuAtpo='M6M71N2102883'
            Seal1='SEAL-TEST-0001'
            Seal2=''
        }
        Hardware=[pscustomobject]@{
            SystemUUID='11111111-2222-3333-4444-555555555555'
            Motherboard=[pscustomobject]@{SerialNumber='MB-TEST-0001'}
            Memory=@([pscustomobject]@{SerialNumber='RAM-TEST-0001'})
            Storage=@([pscustomobject]@{Model='Samsung SSD 990 PRO 1TB';FriendlyName='Samsung SSD 990 PRO 1TB';SerialNumber='SSD-TEST-0001';BusType='NVMe'})
        }
    }
    $manifest=Join-Path $temp 'hardware-qc-manifest.json'
    $manifestObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $context=[pscustomobject]@{
        ProjectRoot=$repo
        Settings=[pscustomobject]@{
            Security=[pscustomobject]@{
                SigningCertificateThumbprint=''
                RequireDigitalSignature=$true
                AutoCreateEphemeralCertificate=$true
                EphemeralKeyLength=2048
            }
        }
    }

    $security=Protect-SitecManifest -ManifestPath $manifest -Context $context
    if (-not $security.Signed) { throw 'Expected signed evidence.' }
    if (-not $security.ManifestSignatureVerified -or -not $security.HardwareIdentitySignatureVerified) { throw 'Immediate signature verification did not pass.' }
    if ($security.SignatureMode -ne 'EphemeralSelfSigned') { throw "Unexpected signature mode: $($security.SignatureMode)" }
    if ($security.PrivateKeyRetained) { throw 'Ephemeral private key must not be retained.' }

    $identity=Join-Path $temp 'hardware-identity.txt'
    $identitySha=Join-Path $temp 'hardware-identity.sha256'
    $identitySig=Join-Path $temp 'hardware-identity.txt.sig'
    $manifestSig=$manifest+'.sig'
    $cert=Join-Path $temp 'evidence-signing.cer'
    foreach($path in @($identity,$identitySha,$identitySig,$manifestSig,$cert,(Join-Path $temp 'signature-verification.json'))) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing evidence artifact: $path" }
    }

    $actual=(Get-FileHash -LiteralPath $identity -Algorithm SHA256).Hash.ToUpperInvariant()
    $declared=((Get-Content -LiteralPath $identitySha -TotalCount 1) -split '\s+')[0].ToUpperInvariant()
    if ($actual -ne $security.HardwareIdentitySha256 -or $declared -ne $actual) {
        throw "HWID file hash mismatch: actual=$actual result=$($security.HardwareIdentitySha256) declared=$declared"
    }
    if (-not (Test-SitecEvidenceSignature -DataPath $manifest -SignaturePath $manifestSig -CertificatePath $cert)) { throw 'Manifest signature verification failed.' }
    if (-not (Test-SitecEvidenceSignature -DataPath $identity -SignaturePath $identitySig -CertificatePath $cert)) { throw 'Identity signature verification failed.' }

    $stillThere=Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object Thumbprint -eq $security.Thumbprint
    if ($stillThere) { throw 'Ephemeral signing certificate/private key was not removed from the certificate store.' }

    [IO.File]::AppendAllText($identity,'TAMPER',[Text.Encoding]::ASCII)
    if (Test-SitecEvidenceSignature -DataPath $identity -SignaturePath $identitySig -CertificatePath $cert) { throw 'Tampered identity unexpectedly verified.' }

    Write-Host 'Security integrity, byte-stable HWID and one-time signature tests passed.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
