# SITEC Hardware Identity v2

`SITEC-HWID-V2` is a hardware-only identity fingerprint. It is intentionally independent from Windows installation state, Asset ID, tamper-seal number, BIOS version, drivers, benchmark results, timestamps, disk free space and attached USB devices.

Canonical identity inputs:

- SMBIOS System UUID, when available
- motherboard serial number
- CPU Full ATPO
- PSU serial number
- sorted RAM serial numbers
- sorted serial numbers of internal storage devices that match the configured BOM profile

Asset ID and tamper seal remain evidence fields in the Baseline JSON/PDF, but they are not part of the hardware identity hash.

The canonical text is normalized to uppercase with whitespace removed, joined with LF, encoded as UTF-8 without BOM, then hashed with SHA-256.

Expected behavior:

- reinstalling/replacing Windows: same HWID
- changing drivers, BIOS version, benchmark results, temperature or free disk space: same HWID
- changing Asset ID or tamper seal only: same HWID
- connecting/disconnecting USB storage: same HWID
- replacing motherboard, CPU, RAM, internal SSD/NVMe or PSU with a different serialized unit: different HWID
