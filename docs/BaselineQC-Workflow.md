# Production BaselineQC workflow

This is the approved production/handover workflow for **SitecQC v3.10.0**.

## Preparation on each PC

Create:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Do not connect the company archive USB during hardware discovery, benchmark or burn-in. Removable storage is intentionally excluded from the production run.

A USB barcode/2D scanner may remain connected because it is used as an input/HID device rather than storage.

## Asset ID and QC working folder

After the operator confirms the Asset ID, SitecQC derives the temporary QC data root from that ID. A shared `C:\SitecQC-Data` folder is not used by the normal production GUI.

```text
CASE-001  -> C:\SitecQC-Data-001
CASE-027  -> C:\SitecQC-Data-027
PC-200    -> C:\SitecQC-Data-200
CASE-TEST -> C:\SitecQC-Data-CASE-TEST
```

Before a new run for the same Asset ID, stale residue in that Asset-specific scratch root is removed. The folder is transient working data and is deleted during normal final cleanup; durable evidence remains under `C:\BaselineQC\Output`.

## Operator sequence

1. Launch `C:\BaselineQC\SitecQC.exe` and approve UAC.
2. Review detected motherboard, CPU, RAM, internal storage, BIOS and other hardware.
3. Confirm/scan **Asset ID**.
4. Scan **PSU Serial**.
5. Scan **CPU Full ATPO** from the Intel 2D matrix/controlled box label.
6. Confirm **Tamper seal #1**. It follows Asset ID automatically unless the physical seal uses a different value.
7. Run **FULL QC + FINALIZE**.
8. Wait for PASS/FAIL.

The production Profile, Operator and Tamper seal #2 are not operator entry fields.

## RAM presentation rule

The detected RAM data remains unchanged internally and in machine-readable evidence. This is important because RAM serials still participate in hardware identity and later comparison.

For customer-facing presentation only:

- the UI hardware summary displays the RAM manufacturer as **Crucial** regardless of the SMBIOS-reported brand/model;
- the PDF Memory Modules table displays Manufacturer as **Crucial**;
- the PDF omits RAM **Part Number**, **Serial** and **Speed** columns;
- raw detected manufacturer, part number, serial and speed remain available in the JSON output.

## QC sequence

SitecQC performs:

```text
Hardware inventory
        ↓
Asset-scoped scratch root
        ↓
Expected-BOM validation
        ↓
Performance qualification
        ↓
Concurrent CPU + RAM + NVMe + graphics burn-in
        ↓
WHEA + sensor validation
        ↓
SITEC-HWID-V2
        ↓
Two-page PDF + Baseline JSON + Full JSON
        ↓
Cleanup of transient files
```

## Successful local output

After PASS:

```text
C:\BaselineQC\
├── SitecQC.exe
└── Output\
    ├── <AssetId>-QC-Certificate.pdf
    ├── <AssetId>-Baseline.json
    └── <AssetId>-Full.json
```

The PDF is the customer/internal paper certificate. `Baseline.json` is the compact record used by the company archive/master Excel process and includes the `ExcelInventory` projection. `Full.json` is the complete machine-readable QC record and preserves the detailed hardware inventory, physical identifiers, BOM checks, benchmark/burn-in results, WHEA data, validation results and evidence hashes/signature metadata that are available for the run.

A failed run may additionally keep one `<AssetId>-LastFailure.zip` under `Output` for troubleshooting.

## Customer acceptance and sealing

1. Keep the PC powered on.
2. Show the customer the displayed technical specifications.
3. Print/review the two-page PDF.
4. Confirm that the printed Asset ID / tamper seal matches the case being handed over.
5. Apply the physical tamper seal in front of the customer.
6. Complete customer acceptance.

The printed PDF may be placed inside the case/package according to the handover procedure.

## Company archive transfer

After SitecQC is completely closed:

1. connect the company archive USB;
2. manually copy `<AssetId>-QC-Certificate.pdf`, `<AssetId>-Baseline.json` and `<AssetId>-Full.json`;
3. transfer/import the required machine-readable fields into the protected master Excel/archive;
4. retain those company-side records as the authoritative long-term baseline.

Cross-PC duplicate-serial detection, fleet-level auditing and later returned-PC comparison are company-side operations. No durable fleet database or serial index is intentionally stored under ProgramData on the delivered PC.

## HWID rule

`SITEC-HWID-V2` is hardware-only:

- reinstalling Windows must **not** change HWID;
- changing Asset ID or tamper seal alone must **not** change HWID;
- changing BIOS version/drivers/benchmark results must **not** change HWID;
- changing only customer-facing RAM display text must **not** change HWID;
- replacing a serialized core component (motherboard, CPU, RAM, internal SSD/NVMe or PSU) **must** change HWID.

The `SitecQC-Data-*` scratch-folder name and presentation-only RAM label are not part of the hardware identity.

See `HWID-v2.md` and `EVIDENCE-INTEGRITY.md` for the exact identity model.
