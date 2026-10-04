# Production BaselineQC workflow

This is the approved production/handover workflow for **SitecQC v3.21.0**.

## Preparation on each PC

Create:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Do not connect USB/removable storage during hardware discovery, benchmark or burn-in. Removable storage is intentionally excluded from the production run. Final QC evidence is transferred over the isolated QC LAN instead of by flash drive.

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
3. The **Asset ID** field starts as `CASE-`. Enter/scan the unique suffix (for example `CASE-001`) and confirm it.
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
Two-page PDF + Full JSON
        ↓
Verified SMB transfer to \\10.50.50.20\QC-Results\<PC-ID>\
        ↓
Cleanup: keep only QC-Certificate.pdf locally
```

## Successful output and retention

After both final files are transferred and SHA-256 verified on the collector, the tested PC retains only:

```text
C:\BaselineQC\
├── SitecQC.exe
└── Output\
    └── <PC-ID>-QC-Certificate.pdf
```

The collector contains:

```text
\\10.50.50.20\QC-Results\<PC-ID>\
├── <PC-ID>-QC-Certificate.pdf
└── <PC-ID>-Full.json
```

The PDF is the customer/internal certificate. `Full.json` is the authoritative machine-readable QC record and contains the Excel-compatible inventory projection together with detailed hardware inventory, physical identifiers, BOM checks, benchmark/burn-in results, WHEA data, validation results and evidence hashes/signature metadata.

If network transfer or verification fails, SitecQC preserves the local Full JSON to prevent evidence loss. A failed run may additionally keep one `<PC-ID>-LastFailure.zip` under `Output` for troubleshooting.

## Customer acceptance and sealing

1. Keep the PC powered on.
2. Show the customer the displayed technical specifications.
3. Print/review the two-page PDF.
4. Confirm that the printed Asset ID / tamper seal matches the case being handed over.
5. Apply the physical tamper seal in front of the customer.
6. Complete customer acceptance.

The printed PDF may be placed inside the case/package according to the handover procedure.

## Company archive transfer

No archive flash drive is required. SitecQC transfers the two final files automatically to:

```text
\\10.50.50.20\QC-Results\<PC-ID>\
```

The operator may manage the collector credential directly in **Network export settings** using the editable Username and masked Password fields. A non-empty Password is written to Windows Credential Manager when **Save settings**, **Open**, or **Test connection** is used, then the Password field is cleared. With a valid stored credential, **Open** launches the collector root in Windows Explorer without a credential prompt.

The required machine-readable fields are imported from the network `Full.json` into the protected master Excel/archive. Cross-PC duplicate-serial detection, fleet-level auditing and later returned-PC comparison are company-side operations. No durable fleet database or serial index is intentionally stored under ProgramData on the delivered PC.

## HWID rule

`SITEC-HWID-V2` is hardware-only:

- reinstalling Windows must **not** change HWID;
- changing Asset ID or tamper seal alone must **not** change HWID;
- changing BIOS version/drivers/benchmark results must **not** change HWID;
- changing only customer-facing RAM display text must **not** change HWID;
- replacing a serialized core component (motherboard, CPU, RAM, internal SSD/NVMe or PSU) **must** change HWID.

The `SitecQC-Data-*` scratch-folder name and presentation-only RAM label are not part of the hardware identity.

See `HWID-v2.md` and `EVIDENCE-INTEGRITY.md` for the exact identity model.
