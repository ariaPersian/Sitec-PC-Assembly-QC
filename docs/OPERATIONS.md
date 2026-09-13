# Production Operations Guide

This document describes the production procedure for **SitecQC v3.9.1 / BaselineQC-local / Asset-scoped data root**.

## 1. Production package and location

Use the versioned GitHub Release executable as the authoritative operator package, for example `SitecQC-Windows-x64-v3.9.1.exe`. Each Release also contains a matching `.sha256` file so the downloaded executable can be verified independently. The ordinary GitHub Actions artifact named `SitecQC-Windows-x64` is only a short-lived secondary copy retained for 3 days.

On every assembled PC create:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Rename/copy the downloaded versioned executable to `C:\BaselineQC\SitecQC.exe` for the production station workflow.

Run the executable from the local system drive. It requests Administrator elevation and extracts its embedded launcher payload only to a disposable `%TEMP%\SitecQC-App-*` location. No persistent application payload, fleet database or baseline database is required under ProgramData.

Normal operators run only `SitecQC.exe`. Repository PowerShell scripts are development/support tools.

## 2. USB/removable-storage rule

**No USB flash drive, USB storage device, SD card or MMC storage should be connected during hardware discovery or QC.**

The application checks the storage inventory before starting a production run and blocks QC if removable storage is present. This keeps the storage inventory and evidence baseline limited to the assembled PC itself.

A USB barcode/2D scanner is acceptable because it behaves as an input/HID device rather than a storage device.

The company archive USB is connected only **after SitecQC is closed** and the QC output has been finalized.

## 3. Automatic collection

On startup SitecQC reads the hardware information that Windows/SMBIOS can expose, including:

- motherboard manufacturer/model/serial;
- CPU model/core/thread information;
- each RAM module and its slot, part number, serial and configured speed;
- internal SSD/NVMe model, vendor serial, firmware, capacity and supported health/reliability data;
- BIOS/SMBIOS information;
- GPU/network inventory;
- System UUID;
- PnP/device errors;
- Windows information for documentation;
- sensor/thermal/load information during QC when supported.

The current batch profile also supplies the expected fixed assembly information (Case, PSU model and CPU cooler model) so the operator does not type those values.

## 4. Operator-entered/scanned values

Production operator fields are intentionally limited to:

- **Asset ID**
- **PSU Serial**
- **CPU 2D / Full ATPO**
- **Tamper seal #1**

Tamper seal #1 automatically follows the Asset ID and may be overwritten if the physical seal uses a different serial.

Profile, Operator and Tamper seal #2 are not production input fields.

Use a scanner whenever possible. CPU Full ATPO should come from Intel's 2D matrix/box label; the Windows ProcessorId/CPUID is not a replacement for the unique Full ATPO.

## 5. Asset-scoped QC data root

The normal production GUI no longer uses a single shared `C:\SitecQC-Data` scratch folder. Once the Asset ID is confirmed, the working folder is derived from that Asset ID.

Examples:

```text
Asset ID     Scratch data root
CASE-001  -> C:\SitecQC-Data-001
CASE-027  -> C:\SitecQC-Data-027
PC-200    -> C:\SitecQC-Data-200
```

The trailing numeric serial is preserved exactly, including leading zeroes. If the Asset ID has no trailing numeric portion, the safe complete Asset ID is used instead, for example `CASE-TEST -> C:\SitecQC-Data-CASE-TEST`.

Before a new run starts for the same Asset ID, SitecQC removes stale residue from that Asset-specific scratch root. This avoids carrying benchmark/log/index data from an interrupted older run into the new run.

The `SitecQC-Data-*` directory is **not** the final evidence archive. It is transient runtime data and is deleted during normal final cleanup.

## 6. Normal operator procedure

1. Confirm that no removable storage is attached.
2. Open `C:\BaselineQC\SitecQC.exe` and approve UAC.
3. Review automatically detected hardware.
4. Confirm/scan Asset ID. At run start, SitecQC creates the corresponding `C:\SitecQC-Data-*` scratch folder.
5. Scan PSU Serial.
6. Scan CPU Full ATPO.
7. Confirm Tamper seal #1 (normally already copied from Asset ID).
8. Click **RUN FULL QC + FINALIZE**.
9. Wait for PASS/FAIL.
10. Open/print the generated two-page PDF.

Hardware discovery occurs automatically at startup; use **Refresh Hardware** only after a real hardware/configuration change.

## 7. QC workload

Production QC includes:

- expected-BOM validation;
- WinSAT CPU/memory qualification;
- CPU stress across logical processors;
- deterministic RAM write/verify testing;
- DiskSpd sequential read/write and random-read qualification;
- concurrent CPU + RAM + NVMe + graphics burn-in;
- Windows WHEA hardware-error capture;
- LibreHardwareMonitor sensor sampling when supported.

DiskSpd operates on temporary test files rather than intentionally targeting a raw physical disk. Temporary workload files are removed during cleanup.

## 8. PASS/FAIL policy

A normal PASS requires the expected BOM and mandatory physical identifiers to validate, CPU/RAM/storage workloads to complete, deterministic RAM errors to remain zero, and WHEA hardware errors to remain zero. Thresholds remain versioned in the project profile/configuration.

Cross-PC duplicate-serial detection is **not** persisted on the customer PC. Duplicate checks across the fleet belong to the company-side archive/master Excel workflow after Baseline JSON files are collected.

## 9. Local durable output

On a successful run the customer PC keeps only compact handover data:

```text
C:\BaselineQC\
├── SitecQC.exe
└── Output\
    ├── <AssetId>-QC-Certificate.pdf
    └── <AssetId>-Baseline.json
```

The PDF is the human-readable document for the customer and internal paper record. The JSON is the machine-readable record for later copy to the company archive/Excel process.

The Baseline JSON contains an `ExcelInventory` projection aligned with the master hardware-inventory workbook. Automatically detected/QC fields are populated there; manual assembly-checklist actions remain separate and are not falsely marked complete by the software.

A failed/error run may additionally leave:

```text
C:\BaselineQC\Output\<AssetId>-LastFailure.zip
```

This is only for troubleshooting. A later successful run removes the stale failure bundle.

## 10. Temporary runtime data

During a production QC run, transient benchmark/log/manifest material is written under the Asset-specific working root, for example:

```text
Asset ID: CASE-001
C:\SitecQC-Data-001\
└── Assets\CASE-001\Runs\CASE-001-<timestamp>\...
```

The launcher payload itself is still extracted under `%TEMP%\SitecQC-App-*`.

After finalization, the Asset-specific scratch root and launcher payload are deleted. They are not part of the delivered evidence set. The durable evidence is only the PDF/Baseline JSON plus `LastFailure.zip` when a failed run needs troubleshooting.

## 11. Customer handover

The intended handover procedure is:

1. SitecQC finishes with PASS while the company archive USB remains disconnected.
2. The customer reviews the powered-on PC and its detected specifications.
3. The two-page PDF is printed/reviewed.
4. The case is physically sealed in front of the customer using the recorded tamper seal.
5. SitecQC is closed.
6. The company archive USB is connected.
7. `<AssetId>-QC-Certificate.pdf` and `<AssetId>-Baseline.json` are copied manually to the company archive.
8. The Baseline JSON values are transferred/imported into the protected master Excel/fleet archive.

This means reformatting the customer's Windows installation later does not destroy the company-held baseline.

## 12. Hardware Identity v2

`SITEC-HWID-V2` is intentionally OS-independent. It uses only:

- SMBIOS System UUID;
- motherboard serial;
- CPU Full ATPO;
- PSU serial;
- sorted RAM serials;
- sorted internal BOM-matching storage serials.

It intentionally excludes Asset ID, tamper seal, Windows, BIOS version, drivers, benchmark values, temperatures, timestamps, free disk space, network state, USB devices and the `SitecQC-Data-*` scratch path.

Expected behavior:

- reinstall/replace Windows -> **same HWID**;
- change Asset ID/seal only -> **same HWID**;
- update BIOS/driver -> **same HWID**;
- replace a serialized core component -> **different HWID**.

See `docs/HWID-v2.md`.

## 13. PDF report

The final customer certificate is strictly two A4 pages:

- **Page 1:** asset/assembly/hardware information;
- **Page 2:** benchmark and burn-in results, validation status, Hardware Identity SHA-256, Manifest SHA-256 and evidence-protection information.

Optional fields with no data are omitted instead of creating visually empty rows. Required missing identity fields cause validation failure.

## 14. Evidence integrity

Two hashes serve different purposes:

- **Hardware Identity SHA-256:** stable hardware fingerprint; expected to remain the same across Windows reinstall/retest while serialized core parts are unchanged.
- **Manifest SHA-256:** integrity hash of the exact QC run evidence; expected to change between runs because timestamps, benchmark results and sensor readings change.

The runtime also supports RSA/SHA-256 evidence signing. Long-term authoritative copies belong in the company-held archive, not only on the delivered PC.

See `docs/EVIDENCE-INTEGRITY.md`.

## 15. Baseline comparison and duplicate detection

The delivered PC does not hold a fleet-wide database. Long-term controls are performed from the company-held copies of the PDF/Baseline JSON and master Excel/archive:

- duplicate motherboard/RAM/SSD/CPU-ATPO/PSU serial detection across the fleet;
- later comparison of a returned PC against its original serialized parts;
- original Asset ID and tamper-seal record;
- HWID comparison;
- preservation of the printed/customer-approved certificate.

This separation is deliberate: customer-side Windows can be reformatted or replaced without becoming the authoritative evidence store.

## 16. PassMark coexistence

PassMark BurnInTest may remain supporting evidence during development/validation, but SitecQC is the production operator workflow and report generator. Additional benchmark engines must remain internal adapters and must not require a separate operator procedure.
