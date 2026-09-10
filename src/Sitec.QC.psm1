Set-StrictMode -Version 2.0
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Functions') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }

function Get-SitecContext {
    [CmdletBinding()]
    param([string]$DataRoot)
    $settingsPath=Join-Path $script:ProjectRoot 'config\appsettings.json'
    $settings=Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) { $settings.DataRoot=$DataRoot }
    [pscustomobject]@{ ProjectRoot=$script:ProjectRoot; Settings=$settings }
}
function Get-SitecProfile {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$ProfileId)
    $path=Join-Path $Context.ProjectRoot ("profiles\{0}.json" -f $ProfileId)
    if (-not (Test-Path -LiteralPath $path)) { throw "Profile not found: $ProfileId" }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}
Export-ModuleMember -Function *-Sitec*
