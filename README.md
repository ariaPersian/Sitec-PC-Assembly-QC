# Sitec PC Assembly QC

Windows production-QC application for **hardware inventory, expected-BOM verification, benchmark/burn-in testing, WHEA error capture, hardware identity, Excel-ready baseline export, complete JSON evidence, and a two-page customer QC certificate**.

Current production workflow: **v3.10.0 / BaselineQC-local / Asset-scoped QC data root**.

The project is being used for a batch of 180 assembled PCs. The operator should enter only information that Windows cannot reliably discover automatically.

## Production workflow

Each PC contains:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Run `SitecQC.exe` locally from the PC being tested. **Do not connect the company archive USB while hardware discovery or QC is running.** Removable storage is deliberately blocked during QC so a flash drive cannot appear in the storage inventory or contaminate the baseline.

The application:

1. requests Administrator elevation;
2. extracts its embedded launcher/runtime payload temporarily under `%TEMP%`;
3. detects the installed hardware;
4. confirms the Asset ID and derives an Asset-scoped scratch-data folder on `C:`;
5. validates the expected BOM;
6. runs performance qualification and full-system burn-in;
7. captures WHEA and sensor evidence;
8. calculates `SITEC-HWID-V2`;
9. generates a two-page PDF, compact Baseline JSON, and complete Full JSON;
10. removes transient benchmark/runtime data after publishing the final evidence.

After SitecQC is closed, the company USB may be connected and the PDF/Baseline/Full JSON files copied manually to the protected company archive and master Excel workflow.

## Asset-scoped SitecQC data root

The production QC working folder is derived from the confirmed Asset ID instead of using one shared `C:\SitecQC-Data` directory.

For Asset IDs ending in digits, the trailing numeric serial is preserved exactly:

```text
Asset ID     QC scratch root
CASE-001  -> C:\SitecQC-Data-001
CASE-027  -> C:\SitecQC-Data-027
PC-200    -> C:\SitecQC-Data-200
```

For an Asset ID without a trailing numeric serial, SitecQC falls back to the complete safe Asset ID, for example `CASE-TEST -> C:\SitecQC-Data-CASE-TEST`.

This folder is **transient working data**, not the authoritative customer output. Before a new run for the same Asset ID, stale residue in that Asset-specific scratch root is removed. After the run is finalized, runtime cleanup removes the scratch data. The durable output remains under `C:\BaselineQC\Output`.

See [`docs/ASSET-DATA-ROOT.md`](docs/ASSET-DATA-ROOT.md) for the exact mapping and lifecycle rule.

## Operator inputs

The normal operator-facing fields are:

- **Asset ID** — organizational/physical case identifier. It also determines the Asset-scoped `SitecQC-Data-*` working folder. Tamper seal #1 follows Asset ID automatically unless the operator overrides it.
- **PSU Serial** — scanned from the installed PSU/controlled packaging.
- **CPU 2D / ATPO** — Intel Full ATPO scanned from the processor 2D matrix or boxed-processor label.
- **Tamper seal #1** — normally the same value as Asset ID; may be edited when the physical seal uses a different serial.

Profile selection, Operator, and Tamper seal #2 are not production operator fields.

The approved batch profile currently records:

- Case: `GREEN AVA+`
- Motherboard: `ASUS TUF GAMING B760-PLUS WIFI`
- CPU: `Intel Core i7-14700K`
- Storage: `Samsung SSD 990 PRO 1TB`
- PSU: `GREEN GP700A-GED V3.1 80PLUS BRONZE ATX 3.1 700W`
- CPU cooler: `DeepCool AG400 PLUS / XuanBing 400 V5 Dual Fan`, P/N `R-AG400-BKNNMD-G`

## Automatic hardware collection

When exposed by Windows/SMBIOS, SitecQC collects:

- motherboard manufacturer/model/serial;
- CPU model, core/thread count and processor information;
- each RAM module: slot, detected manufacturer, part number, serial, capacity, type and configured speed;
- internal SSD/NVMe model, vendor serial, firmware, capacity, bus type and supported reliability counters;
- BIOS/SMBIOS information;
- GPU and network inventory;
- System UUID;
- Windows information for the report only;
- PnP/device-error state;
- temperatures/loads and other supported sensor data during QC.

The raw detected RAM values remain preserved in the machine-readable JSON evidence and continue to participate in validation/HWID where applicable. The customer-facing UI/PDF uses the approved presentation policy described below and does not rewrite the underlying hardware evidence.

Optional values with no real data are omitted from the customer report instead of being rendered as empty rows.

## QC / benchmark stack

Production QC combines:

- Expected-BOM validation;
- WinSAT CPU and memory qualification;
- CPU stress across logical processors;
- deterministic RAM write/verify testing;
- Microsoft DiskSpd sequential and random storage qualification;
- concurrent CPU + RAM + NVMe + graphics burn-in;
- Windows WHEA hardware-error monitoring;
- LibreHardwareMonitor sensor sampling when supported;
- optional PassMark/BurnInTest supporting evidence.

Runtime benchmark XML/log/HTML files are temporary and are removed after completion. A failed run may keep one `LastFailure.zip` under `Output` for troubleshooting.

## Output

The durable customer-PC output is intentionally small:

```text
C:\BaselineQC\
├── SitecQC.exe
└── Output\
    ├── <AssetId>-QC-Certificate.pdf
    ├── <AssetId>-Baseline.json
    └── <AssetId>-Full.json
```

The PDF is the human-readable handover document. `Baseline.json` is the compact machine-readable record aligned with the fleet/Excel workflow. `Full.json` preserves the complete QC run record, including raw detected hardware, physical identifiers, BOM validation, benchmark/burn-in results, WHEA data, validation results, duplicate-serial results, PassMark metadata when present, hardware/manifest hashes, and signature-verification metadata when available.

The Baseline JSON includes an `ExcelInventory` projection whose field names align with the master hardware-inventory workbook. Assembly checklist fields that require a real operator action remain intentionally separate from automatically detected hardware/QC values.

The PDF is exactly two A4 pages:

- **Page 1:** assembled hardware identity/specifications;
- **Page 2:** benchmark/burn-in result, validation status, Hardware Identity SHA-256 and Manifest SHA-256.

### RAM presentation policy

For the customer-facing UI and PDF only:

- RAM manufacturer is displayed as **Crucial** regardless of the SMBIOS-reported manufacturer/model string;
- the PDF RAM table does **not** display Part Number, Serial, or Speed columns;
- the raw detected manufacturer, part number, serial and speed remain unchanged in `Baseline.json`/`Full.json` and in internal validation evidence.

## Hardware Identity v2

`SITEC-HWID-V2` answers: **are the serialized core hardware components still the same?**

It is calculated only from hardware identity fields:

- SMBIOS System UUID;
- motherboard serial;
- CPU Full ATPO;
- PSU serial;
- sorted RAM serials;
- sorted serials of internal storage devices that match the BOM.

The following do **not** affect HWID:

- Windows installation/reinstallation;
- Asset ID or tamper-seal value;
- BIOS version;
- drivers;
- benchmark values;
- temperatures, SSD health/wear or free space;
- timestamps;
- network state;
- attached USB devices.

Therefore reinstalling Windows must keep the same HWID, while replacing a motherboard, CPU, RAM module, internal SSD/NVMe or PSU with a different serialized unit must change the HWID.

See [`docs/HWID-v2.md`](docs/HWID-v2.md).

## Asset ID, seal, HWID and Manifest are different concepts

- **Asset ID:** administrative identity of the physical PC/case and source for the Asset-scoped scratch-folder name.
- **Tamper seal #1:** physical seal identifier used at customer handover.
- **Hardware Identity SHA-256:** identity fingerprint of the serialized core hardware.
- **Manifest SHA-256:** integrity hash of the exact QC evidence for one run; it normally changes between runs because timestamps, temperatures and benchmark results change.

See [`docs/EVIDENCE-INTEGRITY.md`](docs/EVIDENCE-INTEGRITY.md).

## Customer handover

The intended handover sequence is:

1. run QC with USB/removable storage disconnected;
2. obtain PASS and generate the two-page certificate;
3. show the powered-on PC and detected hardware to the customer;
4. print/review the certificate;
5. apply the registered tamper seal in front of the customer;
6. close SitecQC;
7. connect the company USB and manually copy the PDF + Baseline JSON + Full JSON;
8. transfer/import the machine-readable values into the protected master Excel/archive.

Cross-PC duplicate-serial detection and long-term baseline comparison belong to that company-side archive, not to a persistent database on the delivered PC.

## Source / development

Normal operators use only `SitecQC.exe`. Repository scripts such as `Start-SitecQC.ps1`, `Invoke-SitecQC.ps1`, and dependency tooling are retained for development, CI and troubleshooting. If `Invoke-SitecQC.ps1` is started directly without an explicit `-DataRoot`, it resolves the same Asset-scoped data-root rule used by the production GUI.

GitHub Actions validates PowerShell 5.1 syntax, JSON, XAML, runtime smoke tests, Asset-ID data-root mapping, HWID behavior, reporting and the self-contained Windows x64 package. A successful push to `main` publishes the authoritative versioned executable and its SHA-256 file under the matching GitHub Release, for example `SitecQC-Windows-x64-v3.10.0.exe`. The ordinary Actions artifact is only a short-lived secondary copy with a 3-day retention period; older SitecQC Actions artifacts are cleaned before new main-branch uploads, and an Actions-artifact quota problem does not block publishing the versioned Release build.

## Documentation

- [`docs/BaselineQC-Workflow.md`](docs/BaselineQC-Workflow.md) — exact production/handover sequence
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — production operations and troubleshooting policy
- [`docs/ASSET-DATA-ROOT.md`](docs/ASSET-DATA-ROOT.md) — Asset ID to `SitecQC-Data-*` mapping and cleanup lifecycle
- [`docs/HWID-v2.md`](docs/HWID-v2.md) — OS-independent hardware identity definition
- [`docs/EVIDENCE-INTEGRITY.md`](docs/EVIDENCE-INTEGRITY.md) — HWID, manifest hash and signature model
- [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) — third-party components
