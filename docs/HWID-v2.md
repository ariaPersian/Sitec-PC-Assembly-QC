# SITEC Hardware Identity v2

`SITEC-HWID-V2` is the production hardware-only fingerprint used by SitecQC v3.8.0.

Its purpose is simple:

> The same serialized core hardware should produce the same HWID even if Windows, drivers, BIOS version, Asset ID, seal number or benchmark results change.

## Canonical identity inputs

Only the following values participate in the hash when present:

- SMBIOS System UUID;
- motherboard serial number;
- CPU Full ATPO;
- PSU serial number;
- RAM module serial numbers, normalized and sorted;
- internal storage serial numbers that match the configured BOM profile, normalized and sorted.

For the current batch, removable/USB storage is not part of the internal-storage identity set.

## Explicitly excluded

These values do not participate in `SITEC-HWID-V2`:

- Asset ID;
- Tamper seal #1/#2;
- Windows edition/version/build/install state;
- BIOS version/date;
- drivers;
- MAC addresses/network state;
- benchmark/burn-in values;
- WHEA/sensor/temperature data;
- SSD wear/health/power-on hours;
- disk free space;
- timestamps;
- operator/user account;
- USB/removable devices.

Asset ID and tamper seal remain important evidence fields in the PDF/Baseline JSON, but they are intentionally separate from the hardware fingerprint.

## Canonicalization

Identity values are normalized before hashing:

1. convert to uppercase;
2. remove whitespace;
3. sort RAM serials;
4. sort internal BOM-matching storage serials;
5. join canonical lines with LF (`\n`);
6. encode as UTF-8 without BOM;
7. hash with SHA-256.

The schema identifier is:

```text
SCHEMA=SITEC-HWID-V2
```

## Expected behavior

| Change | Expected HWID |
| --- | --- |
| Reinstall Windows | SAME |
| Windows 10 -> Windows 11 | SAME |
| Replace/reformat system Windows | SAME if serialized hardware is unchanged |
| Update BIOS version | SAME |
| Change driver versions | SAME |
| Change Asset ID | SAME |
| Replace/reissue tamper seal only | SAME |
| Connect/disconnect USB storage | SAME |
| Change benchmark/temperature/free space | SAME |
| Replace motherboard with another serialized unit | DIFFERENT |
| Replace CPU with another Full ATPO | DIFFERENT |
| Replace one RAM module | DIFFERENT |
| Replace internal SSD/NVMe, even with the same model | DIFFERENT |
| Replace PSU with another serialized unit | DIFFERENT |

## Why vendor serials matter

Component model names are not enough for anti-tamper comparison. Replacing a `Samsung SSD 990 PRO 1TB` with another `Samsung SSD 990 PRO 1TB` must still change the identity because the vendor serial number changes.

The same principle applies to RAM, motherboard, CPU Full ATPO and PSU serials.

## Relationship to the PDF and Baseline JSON

The two-page PDF displays the Hardware Identity SHA-256 for human comparison. `<AssetId>-Baseline.json` keeps the machine-readable serialized component fields plus the HWID so the company-side archive/master Excel process can perform later comparison and fleet-level checks.

See `EVIDENCE-INTEGRITY.md` for the distinction between Hardware Identity SHA-256 and Manifest SHA-256.
