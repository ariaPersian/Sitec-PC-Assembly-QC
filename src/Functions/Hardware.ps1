function ConvertTo-SitecTrimmedString {
    param($Value)
    if ($null -eq $Value) { return '' }
    ([string]$Value).Trim()
}

function Convert-SmbiosMemoryType {
    param([int]$Type)
    switch ($Type) {
        20 { 'DDR' }
        21 { 'DDR2' }
        24 { 'DDR3' }
        26 { 'DDR4' }
        30 { 'LPDDR4' }
        34 { 'DDR5' }
        35 { 'LPDDR5' }
        default { "Type-$Type" }
    }
}

function Get-SitecStorageReliability {
    param([Parameter(Mandatory)]$PhysicalDisk)
    try {
        $r = $PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop
        [pscustomobject]@{
            TemperatureC = $r.Temperature
            TemperatureMaxC = $r.TemperatureMax
            PowerOnHours = $r.PowerOnHours
            WearPercent = $r.Wear
            ReadErrorsTotal = $r.ReadErrorsTotal
            WriteErrorsTotal = $r.WriteErrorsTotal
            Available = $true
        }
    } catch {
        [pscustomobject]@{
            TemperatureC = $null
            TemperatureMaxC = $null
            PowerOnHours = $null
            WearPercent = $null
            ReadErrorsTotal = $null
            WriteErrorsTotal = $null
            Available = $false
        }
    }
}

function Get-SitecHardwareInventory {
    [CmdletBinding()]
    param()

    $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop | Select-Object -First 1
    $csProduct = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue | Select-Object -First 1
    $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop

    $ram = @()
    foreach ($m in @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)) {
        $ram += [pscustomobject]@{
            Slot = $m.DeviceLocator
            Bank = $m.BankLabel
            Manufacturer = ConvertTo-SitecTrimmedString $m.Manufacturer
            PartNumber = ConvertTo-SitecTrimmedString $m.PartNumber
            SerialNumber = ConvertTo-SitecTrimmedString $m.SerialNumber
            CapacityGB = [math]::Round([double]$m.Capacity / 1GB, 2)
            Type = Convert-SmbiosMemoryType ([int]$m.SMBIOSMemoryType)
            RatedSpeedMHz = $m.Speed
            ConfiguredSpeedMHz = $m.ConfiguredClockSpeed
            ConfiguredVoltage_mV = $m.ConfiguredVoltage
        }
    }

    $physical = @()
    try { $physical = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $physical = @() }
    $wmiDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)
    $disks = @()
    foreach ($d in $physical) {
        $fallback = $wmiDisks | Where-Object {
            ($_.Model -and $d.FriendlyName -and $_.Model -like "*$($d.FriendlyName)*") -or
            ($_.SerialNumber -and $d.SerialNumber -and (ConvertTo-SitecTrimmedString $_.SerialNumber) -eq (ConvertTo-SitecTrimmedString $d.SerialNumber))
        } | Select-Object -First 1
        $rel = Get-SitecStorageReliability -PhysicalDisk $d
        $serial = ConvertTo-SitecTrimmedString $d.SerialNumber
        if ([string]::IsNullOrWhiteSpace($serial) -and $fallback) { $serial = ConvertTo-SitecTrimmedString $fallback.SerialNumber }
        $disks += [pscustomobject]@{
            FriendlyName = $d.FriendlyName
            Model = if ($fallback.Model) { ConvertTo-SitecTrimmedString $fallback.Model } else { $d.FriendlyName }
            SerialNumber = $serial
            FirmwareVersion = $d.FirmwareVersion
            MediaType = [string]$d.MediaType
            BusType = [string]$d.BusType
            SizeGB = [math]::Round([double]$d.Size / 1GB, 2)
            HealthStatus = [string]$d.HealthStatus
            Reliability = $rel
        }
    }
    if ($disks.Count -eq 0) {
        foreach ($d in $wmiDisks) {
            $disks += [pscustomobject]@{
                FriendlyName = $d.Model
                Model = $d.Model
                SerialNumber = ConvertTo-SitecTrimmedString $d.SerialNumber
                FirmwareVersion = $d.FirmwareRevision
                MediaType = $d.MediaType
                BusType = $d.InterfaceType
                SizeGB = [math]::Round([double]$d.Size / 1GB, 2)
                HealthStatus = $d.Status
                Reliability = [pscustomobject]@{ Available=$false }
            }
        }
    }

    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            AdapterRAMGB = if ($_.AdapterRAM) { [math]::Round([double]$_.AdapterRAM / 1GB, 2) } else { $null }
            DriverVersion = $_.DriverVersion
            Status = $_.Status
        }
    })

    $nics = @()
    try {
        $nics = @(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                InterfaceDescription = $_.InterfaceDescription
                MacAddress = $_.MacAddress
                Status = [string]$_.Status
                LinkSpeed = [string]$_.LinkSpeed
            }
        })
    } catch {
        $nics = @(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                InterfaceDescription = $_.Description
                MacAddress = $_.MACAddress
                Status = $_.NetConnectionStatus
                LinkSpeed = $_.Speed
            }
        })
    }

    $pnpErrors = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
        $_.ConfigManagerErrorCode -ne 0
    } | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            ConfigManagerErrorCode = $_.ConfigManagerErrorCode
            Status = $_.Status
            PNPClass = $_.PNPClass
        }
    })

    [pscustomobject]@{
        CollectedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        SystemUUID = ConvertTo-SitecTrimmedString $csProduct.UUID
        SystemEnclosure = [pscustomobject]@{
            Manufacturer = ConvertTo-SitecTrimmedString $enclosure.Manufacturer
            SerialNumber = ConvertTo-SitecTrimmedString $enclosure.SerialNumber
            SMBIOSAssetTag = ConvertTo-SitecTrimmedString $enclosure.SMBIOSAssetTag
            PartNumber = ConvertTo-SitecTrimmedString $enclosure.PartNumber
            ChassisTypes = @($enclosure.ChassisTypes)
        }
        Motherboard = [pscustomobject]@{
            Manufacturer = $board.Manufacturer
            Model = $board.Product
            Version = $board.Version
            SerialNumber = ConvertTo-SitecTrimmedString $board.SerialNumber
        }
        CPU = [pscustomobject]@{
            Model = ConvertTo-SitecTrimmedString $cpu.Name
            Manufacturer = $cpu.Manufacturer
            Socket = $cpu.SocketDesignation
            Cores = $cpu.NumberOfCores
            LogicalProcessors = $cpu.NumberOfLogicalProcessors
            MaxClockMHz = $cpu.MaxClockSpeed
            ProcessorId = $cpu.ProcessorId
        }
        Memory = $ram
        MemoryTotalGB = [math]::Round((($ram | Measure-Object CapacityGB -Sum).Sum), 2)
        Storage = $disks
        BIOS = [pscustomobject]@{
            Manufacturer = $bios.Manufacturer
            Version = $bios.SMBIOSBIOSVersion
            ReleaseDate = if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { $null }
            SMBIOSVersion = "$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)"
        }
        Graphics = $gpus
        Network = $nics
        Windows = [pscustomobject]@{
            Caption = $os.Caption
            Version = $os.Version
            Build = $os.BuildNumber
            Architecture = $os.OSArchitecture
            InstallDate = if ($os.InstallDate) { ([datetime]$os.InstallDate).ToString('o') } else { $null }
        }
        PnPErrors = $pnpErrors
    }
}
