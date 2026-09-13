$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot

[xml]$project=Get-Content -LiteralPath (Join-Path $root 'launcher\SitecQC.Launcher.csproj') -Raw -Encoding UTF8
$version=[string]$project.Project.PropertyGroup.Version
$fileVersion=[string]$project.Project.PropertyGroup.FileVersion
$assemblyVersion=[string]$project.Project.PropertyGroup.AssemblyVersion
if ([string]::IsNullOrWhiteSpace($version)) { throw 'Launcher project Version is empty.' }
if ($fileVersion -ne "$version.0") { throw "FileVersion mismatch: expected $version.0, actual $fileVersion" }
if ($assemblyVersion -ne "$version.0") { throw "AssemblyVersion mismatch: expected $version.0, actual $assemblyVersion" }

$program=Get-Content -LiteralPath (Join-Path $root 'launcher\Program.cs') -Raw -Encoding UTF8
$m=[regex]::Match($program,'AppVersion\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw 'Program.cs AppVersion constant was not found.' }
if ($m.Groups[1].Value -ne $version) { throw "Program.cs AppVersion mismatch: project=$version program=$($m.Groups[1].Value)" }

$workflow=Get-Content -LiteralPath (Join-Path $root '.github\workflows\ci.yml') -Raw -Encoding UTF8
if ($workflow -notmatch 'Publish versioned GitHub Release executable') { throw 'CI does not publish the versioned GitHub Release executable.' }
if ($workflow -notmatch 'retention-days:\s*3') { throw 'CI short-lived Actions artifact retention is not 3 days.' }
if ($workflow -notmatch 'Remove old SitecQC Actions artifacts') { throw 'CI does not clean old SitecQC Actions artifacts.' }
if ($workflow -notmatch 'continue-on-error:\s*true[\s\S]*actions/upload-artifact@v4') { throw 'Actions artifact quota failure is not isolated from the authoritative Release build.' }

Write-Host "Version/distribution policy tests passed for SitecQC v$version." -ForegroundColor Green
