function ConvertTo-SitecExcelText {
    param($Value)
    if ($null -eq $Value) { return '' }
    ([string]$Value).Trim()
}

function Join-SitecExcelValues {
    param([object[]]$Values)
    @($Values | ForEach-Object { ConvertTo-SitecExcelText $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ' | '
}

function Publish-SitecBaselineJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselineRoot,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$CertificatePath=''
    )
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }

    $run=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $storage=@(Get-SitecIdentityStorage -Hardware $run.Hardware -Profile $run.Profile)
    $memory=@($run.Hardware.Memory)

    $ramModels=Join-SitecExcelValues @($memory | ForEach-Object {
        $parts=@((ConvertTo-SitecExcelText $_.Manufacturer),(ConvertTo-SitecExcelText $_.PartNumber)) | Where-Object { $_ }
        $parts -join ' '
    })
    $ramSerials=Join-SitecExcelValues @($memory | Select-Object -ExpandProperty SerialNumber)
    $ssdModels=Join-SitecExcelValues @($storage | Select-Object -ExpandProperty Model)
    $ssdSerials=Join-SitecExcelValues @($storage | Select-Object -ExpandProperty SerialNumber)
    $boardModel=(Join-SitecExcelValues @($run.Hardware.Motherboard.Manufacturer,$run.Hardware.Motherboard.Model)) -replace ' \| ',' '

    $benchmarkStatus=''
    if ($run.PSObject.Properties['BenchmarkValidation'] -and $run.BenchmarkValidation) {
        $benchmarkStatus=ConvertTo-SitecExcelText $run.BenchmarkValidation.Status
    }
    $benchmarkMark=if ($benchmarkStatus -eq 'PASS') { [char]0x2713 } else { '' }
    $serialRegistered=if ([string]$run.OverallStatus -eq 'PASS') { [char]0x2713 } else { '' }
    $certificateFile=if ($CertificatePath) { [IO.Path]::GetFileName($CertificatePath) } else { '' }

    $excelRow=[ordered]@{
        'PC Tag ID'=[string]$run.AssetId
        'CPU '=''
        'SSD'=''
        'CPU Fan'=''
        'PSU install'=''
        'Motherboard Install'=''
        'PIN Connectors'=''
        'Bios Update,PXE'=''
        'Win10'=''
        'Benchmark'=$benchmarkMark
        'BenchMark Files'=$certificateFile
        'Build Status'=[string]$run.OverallStatus
        'Model and serial Registered'=$serialRegistered
        'Case Model'=[string]$run.Physical.CaseModel
        'Motherboard Model'=$boardModel
        'Box Serial No'=''
        'Motherboard Serial No'=[string]$run.Hardware.Motherboard.SerialNumber
        'CPU Model'=[string]$run.Hardware.CPU.Model
        'CPU ATPO'=[string]$run.Physical.CpuAtpo
        'CPU Fan Model'=[string]$run.Physical.Cooler
        'CPU Fan Serial No'=''
        'RAM Model'=$ramModels
        'RAM Serial No'=$ramSerials
        'SSD Model'=$ssdModels
        'SSD Serial No'=$ssdSerials
        'PSU Model'=[string]$run.Physical.PsuModel
        'PSU Serial No'=[string]$run.Physical.PsuSerial
        'Tamper Seal #1'=[string]$run.Physical.Seal1
        'Hardware Identity SHA-256'=[string]$run.Security.HardwareIdentitySha256
        'Manifest SHA-256'=[string]$run.Security.Sha256
        'QC Date'=[string]$run.CompletedAt
    }

    $baseline=[ordered]@{
        Schema='SITEC-BASELINE-V2'
        AssetId=[string]$run.AssetId
        TamperSeal=[string]$run.Physical.Seal1
        CreatedAt=[string]$run.CompletedAt
        OverallStatus=[string]$run.OverallStatus
        Profile=[ordered]@{Id=[string]$run.Profile.ProfileId;Version=[string]$run.Profile.ProfileVersion}
        Case=[ordered]@{Model=[string]$run.Physical.CaseModel}
        PowerSupply=[ordered]@{Model=[string]$run.Physical.PsuModel;Serial=[string]$run.Physical.PsuSerial}
        CpuCooler=[ordered]@{Model=[string]$run.Physical.Cooler}
        CPU=[ordered]@{Model=[string]$run.Hardware.CPU.Model;Cores=$run.Hardware.CPU.Cores;LogicalProcessors=$run.Hardware.CPU.LogicalProcessors;Atpo=[string]$run.Physical.CpuAtpo}
        Motherboard=[ordered]@{Manufacturer=[string]$run.Hardware.Motherboard.Manufacturer;Model=[string]$run.Hardware.Motherboard.Model;Serial=[string]$run.Hardware.Motherboard.SerialNumber}
        SystemUUID=[string]$run.Hardware.SystemUUID
        BIOS=[ordered]@{Version=[string]$run.Hardware.BIOS.Version;ReleaseDate=[string]$run.Hardware.BIOS.ReleaseDate}
        Memory=@($memory | ForEach-Object { [ordered]@{Slot=[string]$_.Slot;Manufacturer=[string]$_.Manufacturer;PartNumber=[string]$_.PartNumber;Serial=[string]$_.SerialNumber;CapacityGB=$_.CapacityGB;ConfiguredSpeedMHz=$_.ConfiguredSpeedMHz} })
        Storage=@($storage | ForEach-Object { [ordered]@{Model=[string]$_.Model;Serial=[string]$_.SerialNumber;Firmware=[string]$_.FirmwareVersion;SizeGB=$_.SizeGB;BusType=[string]$_.BusType} })
        Graphics=@($run.Hardware.Graphics | ForEach-Object { [string]$_.Name })
        HardwareIdentity=[ordered]@{Schema=[string]$run.Security.HardwareIdentitySchema;Sha256=[string]$run.Security.HardwareIdentitySha256}
        ManifestSha256=[string]$run.Security.Sha256
        CertificateFile=$certificateFile
        ExcelInventory=$excelRow
    }

    $destination=Get-SitecPublishedBaselinePath -BaselineRoot $BaselineRoot -AssetId $AssetId
    $baseline | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $destination -Encoding UTF8
    $destination
}
