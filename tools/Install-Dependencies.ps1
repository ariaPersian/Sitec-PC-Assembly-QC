#requires -version 5.1
[CmdletBinding()]
param([switch]$SkipSensors,[switch]$Force)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$root=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bin=Join-Path $root 'tools\bin'; New-Item -ItemType Directory -Path $bin -Force | Out-Null
$temp=Join-Path $env:TEMP ('SitecQC-Dependencies-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $diskExe=Join-Path $bin 'diskspd.exe'
    if ($Force -or -not (Test-Path $diskExe)) {
        Write-Host 'Downloading Microsoft DiskSpd 2.2 from the official GitHub release...' -ForegroundColor Cyan
        $zip=Join-Path $temp 'DiskSpd.zip'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/microsoft/diskspd/releases/latest/download/DiskSpd.zip' -OutFile $zip
        $extract=Join-Path $temp 'diskspd'; Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $candidate=Get-ChildItem -LiteralPath $extract -Filter diskspd.exe -Recurse | Where-Object { $_.FullName -match 'amd64|x64' } | Select-Object -First 1
        if (-not $candidate) { $candidate=Get-ChildItem -LiteralPath $extract -Filter diskspd.exe -Recurse | Select-Object -First 1 }
        if (-not $candidate) { throw 'DiskSpd executable was not found in the downloaded archive.' }
        Copy-Item -LiteralPath $candidate.FullName -Destination $diskExe -Force
        Write-Host "Installed: $diskExe" -ForegroundColor Green
    }

    if (-not $SkipSensors) {
        $lhmRoot=Join-Path $root 'tools\librehardwaremonitor'
        $existing=Get-ChildItem -LiteralPath $lhmRoot -Filter LibreHardwareMonitorLib.dll -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Force -or -not $existing) {
            Write-Host 'Downloading LibreHardwareMonitor v0.9.6 from the official GitHub release...' -ForegroundColor Cyan
            if (Test-Path $lhmRoot) { Remove-Item $lhmRoot -Recurse -Force }
            New-Item -ItemType Directory -Path $lhmRoot -Force | Out-Null
            $zip=Join-Path $temp 'LibreHardwareMonitor.zip'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip' -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $lhmRoot -Force
            $dll=Get-ChildItem -LiteralPath $lhmRoot -Filter LibreHardwareMonitorLib.dll -Recurse | Select-Object -First 1
            if (-not $dll) { throw 'LibreHardwareMonitorLib.dll was not found in the downloaded archive.' }
            if ($dll.DirectoryName -ne $lhmRoot) {
                Get-ChildItem -LiteralPath $dll.DirectoryName -File | Copy-Item -Destination $lhmRoot -Force
            }
            Write-Host "Installed sensor library: $(Join-Path $lhmRoot 'LibreHardwareMonitorLib.dll')" -ForegroundColor Green
        }
    }
    Write-Host 'Dependency installation complete.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
