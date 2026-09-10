# Normalize storage identity after the base hardware collector runs.
# Get-PhysicalDisk can expose an NVMe controller/EUI-style identifier where
# Win32_DiskDrive exposes the manufacturer serial printed on the device.
# Preserve both, but use the manufacturer serial as the primary evidence ID.

$script:SitecHardwareInventoryCore = ${function:Get-SitecHardwareInventory}

function Get-SitecHardwareInventory {
    [CmdletBinding()]
    param()

    $hardware=& $script:SitecHardwareInventoryCore
    try {
        $wmiDisks=@(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)
        foreach ($disk in @($hardware.Storage)) {
            if ($null -eq $disk) { continue }
            $controllerIdentifier=[string]$disk.SerialNumber
            $model=[string]$disk.Model
            $friendly=[string]$disk.FriendlyName

            $match=$wmiDisks | Where-Object {
                $wm=[string]$_.Model
                (-not [string]::IsNullOrWhiteSpace($model) -and ($wm -eq $model -or $wm -like ('*'+$friendly+'*') -or $model -like ('*'+$wm+'*'))) -or
                (-not [string]::IsNullOrWhiteSpace($friendly) -and $wm -like ('*'+$friendly+'*'))
            } | Select-Object -First 1

            if ($match) {
                $vendorSerial=([string]$match.SerialNumber).Trim()
                if (Test-SitecUsefulIdentifier $vendorSerial) {
                    if (-not $disk.PSObject.Properties['ControllerIdentifier']) {
                        $disk | Add-Member -NotePropertyName ControllerIdentifier -NotePropertyValue $controllerIdentifier
                    } else {
                        $disk.ControllerIdentifier=$controllerIdentifier
                    }
                    $disk.SerialNumber=$vendorSerial
                }
            }
        }
    } catch {}
    $hardware
}
