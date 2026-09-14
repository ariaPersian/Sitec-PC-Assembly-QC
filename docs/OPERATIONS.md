# Production Operations Guide

This document describes the production procedure for **SitecQC v3.10.0 / BaselineQC-local / Asset-scoped data root**.

## 1. Production package and location

Use the versioned GitHub Release executable as the authoritative operator package, for example `SitecQC-Windows-x64-v3.10.0.exe`. Each Release also contains a matching `.sha256` file. The ordinary GitHub Actions artifact named `SitecQC-Windows-x64` is only a short-lived secondary copy.

On every assembled PC create:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Rename/copy the downloaded versioned executable to `C:\BaselineQC\SitecQC.exe`. Run it from the local system drive. The launcher requests Administrator elevation and uses only disposable `%TEMP%\SitecQC-App-*` payload data. No persistent application/fleet database is required under ProgramData.

## 2. USB/removable-storage rule

**No USB flash drive, USB storage device, SD card or MMC storage should be connected during hardware discovery or QC.** A USB barcode/2D scanner is acceptable because it is an input/HID device rather than storage.

Connect the company archive USB only after SitecQC has finished and been closed.

## 3. Automatic collection

SitecQC reads the hardware data exposed by Windows/SMBIOS, including motherboard, CPU, each RAM module, internal storage, BIOS/SMBIOS, GPU/network inventory, System UUID, device-error state and supported sensor/thermal data.

For RAM, the raw detected slot, manufacturer, part number, serial, capacity, type and speed are retained internally and in JSON evidence. These raw values are not rewritten by the customer-facing presentation policy.

## 4. Operator-entered/scanned values

Production operator fields are intentionally limited to:

- **Asset ID**
- **PSU Serial**
- **CPU 2D / Full ATPO**
- **Tamper seal #1**

Tamper seal #1 automatically follows Asset ID and may be overwritten when the physical seal uses a different serial. Profile, Operator and Tamper seal #2 are not production input fields.

## 5. Asset-scoped QC data root

The production GUI derives the transient working folder from Asset ID:

```text
CASE-001  -> C:\SitecQC-Data-001
CASE-027  -> C:\SitecQC-Data-027
PC-200    -> C:\SitecQC-Data-200
CASE-TEST -> C:\SitecQC-Data-CASE-TEST
```

Before a new run for the same Asset ID, stale residue is removed. After finalization the Asset-specific scratch root is deleted. It is not the authoritative evidence archive.

## 6. Normal operator procedure

1. Confirm no removable storage is attached.
2. Open `C:\BaselineQC\SitecQC.exe` and approve UAC.
3. Review automatically detected hardware.
4. Confirm/scan Asset ID.
5. Scan PSU Serial.
6. Scan CPU Full ATPO.
7. Confirm Tamper seal #1.
8. Click **RUN FULL QC + FINALIZE**.
9. Wait for PASS/FAIL.
10. Open/print the generated two-page PDF.

Hardware discovery occurs automatically at startup; use **Refresh Hardware** only after a real hardware/configuration change.

## 7. RAM presentation policy

The policy applies **only to the operator/customer display**, not to hardware evidence:

- the top UI RAM line displays manufacturer as `Crucial` regardless of the SMBIOS-reported manufacturer/model;
- the PDF RAM Manufacturer column always displays `Crucial`;
- the PDF RAM table omits **Part Number**, **Serial** and **Speed** columns;
- raw detected RAM manufacturer, part number, serial and speed remain present in machine-readable output and continue to be used by validation/HWID logic where applicable.

The UI may still show operational RAM serial/speed information; only the brand/model presentation is normalized there.

## 8. QC workload and PASS/FAIL

Production QC includes expected-BOM validation, WinSAT CPU/memory qualification, CPU stress, deterministic RAM write/verify, DiskSpd storage qualification, concurrent CPU/RAM/NVMe/graphics burn-in, WHEA capture and supported sensor sampling.

A normal PASS requires expected BOM and mandatory identifiers to validate, required workloads to complete, deterministic RAM errors to remain zero and WHEA hardware errors to remain zero.

## 9. Local durable output

On a successful run:

```text
C:\BaselineQC\
├── SitecQC.exe
└── Output\
    ├── <AssetId>-QC-Certificate.pdf
    ├── <AssetId>-Baseline.json
    └── <AssetId>-Full.json
```

`QC-Certificate.pdf` is the human-readable handover document. `Baseline.json` is the compact machine-readable fleet/Excel record. `Full.json` is the detailed machine-readable QC record and preserves the complete run object available at finalization: raw hardware inventory, physical identifiers, BOM validation, benchmark/burn-in data, WHEA data, validation status, duplicate-serial results, PassMark metadata when present, and hardware/manifest hashes plus signature-verification metadata when available.

A failed/error run may additionally leave:

```text
C:\BaselineQC\Output\<AssetId>-LastFailure.zip
```

A later successful run removes the stale failure bundle.

## 10. Temporary runtime data

During a production run, transient benchmark/log/manifest material lives under the Asset-specific working root, for example:

```text
C:\SitecQC-Data-001\Assets\CASE-001\Runs\CASE-001-<timestamp>\...
```

The launcher payload is extracted under `%TEMP%\SitecQC-App-*`. After finalization, scratch/runtime data is removed. Durable evidence is the PDF, Baseline JSON and Full JSON, plus `LastFailure.zip` only when troubleshooting a failed run.

## 11. Customer handover

1. SitecQC finishes while the company archive USB remains disconnected.
2. The customer reviews the powered-on PC and displayed specifications.
3. The two-page PDF is printed/reviewed.
4. The case is physically sealed in front of the customer using the recorded tamper seal.
5. SitecQC is closed.
6. The company archive USB is connected.
7. Copy `<AssetId>-QC-Certificate.pdf`, `<AssetId>-Baseline.json` and `<AssetId>-Full.json` to the company archive.
8. Import/transfer required fields into the protected master Excel/fleet archive.

## 12. Hardware Identity v2

`SITEC-HWID-V2` uses hardware identity only: SMBIOS System UUID, motherboard serial, CPU Full ATPO, PSU serial, sorted RAM serials, and sorted internal BOM-matching storage serials.

It excludes Windows, Asset ID/seal, BIOS version, drivers, benchmark values, temperatures, timestamps, free disk space, network state, USB devices, scratch paths and presentation-only labels. Therefore changing the RAM display text to `Crucial` does not change HWID; replacing a serialized RAM module does.

## 13. PDF report

The final customer certificate remains exactly two A4 pages:

- **Page 1:** asset/assembly/hardware information with the RAM presentation policy above;
- **Page 2:** benchmark and burn-in results, validation status, Hardware Identity SHA-256, Manifest SHA-256 and evidence-protection information.

## 14. Evidence integrity and company archive

Hardware Identity SHA-256 is the stable serialized-hardware fingerprint. Manifest SHA-256 identifies the exact QC run evidence and normally changes between runs. RSA/SHA-256 evidence signing remains supported.

Long-term duplicate-serial detection, baseline comparison and returned-PC verification are performed from company-held PDF/JSON records and the protected master archive, not from a persistent customer-PC fleet database.

## 15. PassMark coexistence

PassMark BurnInTest may remain supporting evidence during development/validation, but SitecQC is the production operator workflow and report generator. Additional benchmark engines must remain internal adapters and must not require a separate operator procedure.
