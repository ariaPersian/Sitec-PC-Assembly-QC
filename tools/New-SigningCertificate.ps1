#requires -version 5.1
[CmdletBinding()]
param([string]$Subject='CN=SITEC Hardware QC Signing',[int]$Years=5)
$cert=New-SelfSignedCertificate -Subject $Subject -Type CodeSigningCert -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears($Years)
Write-Host "Created signing certificate: $($cert.Thumbprint)" -ForegroundColor Green
Write-Host 'Put this thumbprint in config/appsettings.json -> Security.SigningCertificateThumbprint.'
Write-Host 'Export and protect the private key separately if multiple authorized QC stations must sign manifests.'
$cert | Format-List Subject,Thumbprint,NotAfter,HasPrivateKey
