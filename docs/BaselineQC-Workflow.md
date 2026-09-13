# Production BaselineQC workflow

This is the approved production/handover workflow for **SitecQC v3.9.1**.

## Preparation on each PC

Create:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Do not connect the company archive USB during hardware discovery, benchmark or burn-in. Removable storage is intentionally excluded from the production run.

A USB barcode/2D scanner may remain connected because it is used as an input/HID device rather than storage.

## Asset ID and QC working folder

After the operator confirms the Asset ID, SitecQC derives the temporary QC data root from that ID. A shared `C:\SitecQC-Data` folder is no longer used by the normal production GUI.

For the production numeric labels:

```text
CASE-001  -> C:\SitecQC-Data-001
CASE-027  -> C:\SitecQC-Data-027
PC-200    -> C:\SitecQC-Data-200
```

If an Asset ID does not end in digits, the safe full Asset ID is used as the suffix, for example:

```text
CASE-TEST -> C:\SitecQC-Data-CASE-TEST
```

Before a new run for the same Asset ID, stale residue in that Asset-specific scratch root is removed. The folder is transient working data and is deleted during normal final cleanup; the durable evidence remains under `C:\BaselineQC\Output`.

## Operator sequence

1. Launch `C:\BaselineQC\SitecQC.exe` and approve UAC.
2. Review detected motherboard, CPU, RAM, internal storage, BIOS and other hardware.
3. Confirm/scan **Asset ID**. This determines the `C:\SitecQC-Data-*` scratch folder used for the run.
4. Scan **PSU Serial**.
5. Scan **CPU Full ATPO** from the Intel 2D matrix/controlled box label.
6. Confirm **Tamper seal #1**. It follows Asset ID automatically unless the physical seal uses a different value.
7. Run **FULL QC + FINALIZE**.
8. Wait for PASS/FAIL.

The production Profile, Operator and Tamper seal #2 are not operator entry fields.

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
Two-page PDF + Baseline JSON / ExcelInventory projection
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
    └── <AssetId>-Baseline.json
```

The PDF is the customer/internal paper certificate. The JSON is the compact machine-readable record for the company archive and master Excel process. The JSON includes an `ExcelInventory` projection aligned with the hardware-inventory workbook.

A failed run may keep one `<AssetId>-LastFailure.zip` under `Output` for troubleshooting.

## Customer acceptance and sealing

1. Keep the PC powered on.
2. Show the customer the detected technical specifications and component identities.
3. Print/review the two-page PDF.
4. Confirm that the printed Asset ID / tamper seal matches the case being handed over.
5. Apply the physical tamper seal in front of the customer.
6. Complete customer acceptance.

The printed PDF may be placed inside the case/package according to the handover procedure.

## Company archive transfer

After SitecQC is completely closed:

1. connect the company archive USB;
2. manually copy `<AssetId>-QC-Certificate.pdf` and `<AssetId>-Baseline.json`;
3. transfer/import the machine-readable fields into the protected master Excel/archive;
4. retain those company-side records as the authoritative long-term baseline.

Cross-PC duplicate-serial detection, fleet-level auditing and later returned-PC comparison are company-side operations. No durable fleet database or serial index is intentionally stored under ProgramData on the delivered PC.

## HWID rule

`SITEC-HWID-V2` is hardware-only:

- reinstalling Windows must **not** change HWID;
- changing Asset ID or tamper seal alone must **not** change HWID;
- changing BIOS version/drivers/benchmark results must **not** change HWID;
- replacing a serialized core component (motherboard, CPU, RAM, internal SSD/NVMe or PSU) **must** change HWID.

The `SitecQC-Data-*` scratch-folder name is operational metadata only and is not part of the hardware identity.

See `HWID-v2.md` and `EVIDENCE-INTEGRITY.md` for the exact identity model.
