# Sitec PC Assembly QC

Windows production-QC application for **hardware inventory, optional production-profile comparison, benchmark/burn-in testing, WHEA error capture, hardware identity/integrity validation, Excel-ready baseline export, complete JSON evidence, and a two-page customer QC certificate**.

Current production workflow: **v3.17.0 / BaselineQC-local / Asset-scoped QC data root / operator-selectable benchmark components / optional profile comparison (OFF by default) / independent identity-integrity validation / MaximumSafe CPU-RAM-NVMe-GPU coverage / explicit PASS-FAIL-ERROR-CANCELLED semantics**.

The project is being used for a batch of 180 assembled PCs. The operator should enter only information that Windows cannot reliably discover automatically.

## Production workflow

Each PC contains:

```text
C:\BaselineQC\
└── SitecQC.exe
```

Run `SitecQC.exe` locally from the PC being tested. Keep removable storage disconnected while hardware discovery or QC is running. Removable storage is deliberately blocked during QC so it cannot appear in the storage inventory or contaminate the baseline. SitecQC can automatically export the final PDF and Full JSON to the configured SMB collector after QC completes.

The production profile now acts as a **QC recipe**: it supplies benchmark thresholds, identity-capture requirements and the optional expected-hardware reference. **Hardware/profile comparison is operator-selectable and OFF by default.** When selected, detected CPU/RAM/motherboard/storage/GPU and recorded physical models are compared with the profile and any differences are advisory only. Missing required serials, duplicate serial identities and PnP device errors remain blocking identity/integrity failures regardless of profile-comparison selection. A healthy benchmark with an enabled profile comparison that finds differences is still displayed as hardware `PASS` with a separate profile advisory.

The application:

1. requests Administrator elevation;
2. extracts its embedded launcher/runtime payload temporarily under `%TEMP%`;
3. detects the installed hardware;
4. confirms the Asset ID and derives an Asset-scoped scratch-data folder on `C:`;
5. always validates serialized hardware identity/integrity and, only when selected by the operator, compares hardware with the production profile;
6. runs performance qualification and full-system burn-in;
7. captures WHEA and sensor evidence;
8. calculates `SITEC-HWID-V2`;
9. generates a two-page PDF, compact Baseline JSON, and complete Full JSON;
10. removes transient benchmark/runtime data after publishing the final evidence.

When network export is enabled, the QC Certificate PDF and Full JSON are copied automatically to the configured collector while the local copies remain on the PC. The network export result is independent of the QC PASS/FAIL classification.

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

Profile selection, Operator, and Tamper seal #2 are not production operator fields. The configured QC recipe is shown read-only. The operator may enable **Compare detected hardware with this profile**; it is disabled by default. Hovering over that checkbox/profile display shows the expected hardware in a tooltip.

The default current-system profile is `B760-13700K-64GB-990PRO` and records:

- Case: `GREEN AVA+`
- Motherboard: `ASUS TUF GAMING B760-PLUS WIFI`
- CPU: `Intel Core i7-13700K`
- RAM: `64 GB DDR5` (configured speed >= 4000 MHz)
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

Before each run, the operator can independently select which hardware categories will be benchmarked:

- **CPU** — WinSAT CPU qualification plus CPU burn-in;
- **RAM / Memory** — WinSAT memory bandwidth plus deterministic RAM write/verify;
- **Storage / NVMe** — DiskSpd qualification plus sustained storage burn-in;
- **Graphics / GPU** — graphics workload during burn-in.

All four benchmark categories are selected by default, preserving the previous full-QC behavior. At least one benchmark category must remain selected. Inventory, serialized identity/integrity validation, WHEA monitoring, evidence hashing/signing and report generation always run regardless of benchmark selection. **Profile comparison is a separate optional checkbox and is OFF by default.** Unselected benchmark categories are recorded as `SKIPPED` and are excluded from pass/fail threshold evaluation.

Identity/integrity validation, optional profile comparison and benchmark execution are separate concerns. A profile mismatch **never suppresses benchmarks and never makes an otherwise healthy PC fail QC**; it is recorded as `MISMATCH`/advisory. Overall QC failure is driven by blocking identity/integrity or hardware-health checks and selected benchmark gates.

Process outcomes are deliberately distinct: exit code `0` means completed QC `PASS` (including an advisory profile mismatch), exit code `2` means completed QC `FAIL` or `CANCELLED` because of blocking identity/integrity or selected benchmark gates, and exit code `1` means a real application/runtime error. A normal QC `FAIL` publishes the PDF/Baseline/Full JSON but does **not** create `LastFailure` diagnostics; `LastFailure` is reserved for runtime faults.

Production QC combines:

- blocking serialized hardware identity/integrity validation;
- optional advisory comparison against the current production profile;
- selected WinSAT CPU and/or memory qualification;
- **MaximumSafe CPU:** 100% requested duty on every logical processor, with explicit 100% thread-coverage and sustained/peak utilization gates;
- **MaximumSafe RAM:** deterministic write/verify consumes almost all currently free physical RAM while keeping a dynamic safety reserve of 5% of installed memory, clamped to 2-4 GB; on a typical 64 GB system with about 12 GB already in use, approximately 49-50 GB is requested;
- **MaximumSafe NVMe:** Microsoft DiskSpd uses uncached/write-through I/O, high queue depth and a 4-16 GB temporary test file sized from available free space. Burn-in is intentionally read-only to saturate the controller/NAND without repeatedly overwriting the full SSD; short qualification tests still verify write throughput;
- **MaximumSafe GPU:** WinSAT Direct3D ALU runs off-screen at 1920x1080 as the production graphics stress workload. When Windows GPU performance counters provide valid non-zero telemetry, the configured >=70% average and >=90% peak utilization gates are enforced. Some Intel iGPU/driver combinations return stale zero or near-zero idle-noise counters (for example 0.1%-0.6%) for a successfully completed off-screen WinSAT workload. SitecQC retries the native GPU counter path when CIM remains below 5%; if the final peak still stays below the 5% credibility floor, telemetry is recorded as unavailable/advisory instead of a false hardware failure. Credible telemetry still enforces the configured >=70% average and >=90% peak gates, and failure of the graphics workload itself remains a blocking QC gate;
- concurrent burn-in using only the selected CPU/RAM/NVMe/graphics workloads;
- Windows WHEA hardware-error monitoring;
- LibreHardwareMonitor sensor sampling when supported;
- optional PassMark/BurnInTest supporting evidence.

RAM validation is plan-aware: at least 95% of the calculated safe allocation must actually be reserved, and observed peak RAM usage may fall no more than 5 percentage points below the calculated MaximumSafe target. The legacy fixed `>=70%` peak check remains only as a compatibility fallback for older result records.

Operator feedback during QC now includes an explicit numeric progress percentage plus elapsed and estimated/known remaining time. While a benchmark is active, the GUI exposes a **CANCEL BENCHMARK** action; cancellation stops the owned benchmark process tree, marks the run as `CANCELLED`, and still finalizes the durable evidence instead of treating the operator action as an application crash.

The durable `<AssetId>-Full.json` remains compatible with the rich `SITEC-QC-FULL-V1` structure and is now also produced for runtime-error runs whenever a run directory/partial manifest can be recovered. It contains `ErrorSummary`, `ErrorDetails`, `BenchmarkFailure`, diagnostics metadata and the Excel-compatible inventory projection. Benchmark child exceptions preserve the exact exception type, FullyQualifiedErrorId, PowerShell script stack, position and diagnostic source path. The Full JSON is the authoritative final machine-readable failure/success record; separate `failure-summary.json` and `diagnostics\process.log` files are no longer created or published.

Runtime benchmark XML/log/HTML files are temporary and are removed after completion. Only a real application/runtime fault may keep one `LastFailure.zip` under `Output` for troubleshooting; a completed QC `FAIL` does not.

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

The PDF is the human-readable handover document. `Baseline.json` is the compact machine-readable record aligned with the fleet/Excel workflow. `Full.json` preserves the complete QC run record, including raw detected hardware, physical identifiers, `IdentityValidation`, `ProfileComparisonEnabled`, `ProfileComparison`, compatibility BOM fields, benchmark/burn-in results, WHEA data, validation results, structured `ErrorSummary`/`ErrorDetails`, duplicate-serial results, PassMark metadata when present, hardware/manifest hashes, and signature-verification metadata when available.

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
6. let SitecQC export the QC Certificate PDF + Full JSON to the configured network collector;
7. verify the network export status in the application;
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


## QC network export

The production UI includes a dedicated **Network export settings** panel. The default collector path is `\\10.50.50.20\QC-Results`, the account label is `QCTransfer`, and automatic export is enabled. Use **Copy** to place the UNC path on the clipboard, **Test connection** to verify TCP/445 plus write/delete permission, and **Save settings** to create the machine-local `SitecQC.local.json` override next to the executable.

SMB authentication is deliberately supplied by Windows rather than embedding a password in this public repository. See [docs/network-export.md](docs/network-export.md).
