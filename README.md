# Sitec PC Assembly QC

Windows production-QC application for **hardware inventory, expected-BOM verification, benchmark/burn-in testing, WHEA error capture, hardware identity, and a two-page customer QC certificate**.

Current production workflow: **v3.8.0 / BaselineQC-local**.

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
2. extracts its embedded runtime temporarily under `%TEMP%`;
3. detects the installed hardware;
4. validates the expected BOM;
5. runs performance qualification and full-system burn-in;
6. captures WHEA and sensor evidence;
7. calculates `SITEC-HWID-V2`;
8. generates a two-page PDF and compact Baseline JSON;
9. removes temporary benchmark/runtime files.

After SitecQC is closed, the company USB may be connected and the PDF/Baseline JSON copied manually to the protected company archive and master Excel workflow.

## Operator inputs

The normal operator-facing fields are:

- **Asset ID** — organizational/physical case identifier. Tamper seal #1 follows Asset ID automatically unless the operator overrides it.
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
- each RAM module: slot, manufacturer, part number, serial, capacity, type and configured speed;
- internal SSD/NVMe model, vendor serial, firmware, capacity, bus type and supported reliability counters;
- BIOS/SMBIOS information;
- GPU and network inventory;
- System UUID;
- Windows information for the report only;
- PnP/device-error state;
- temperatures/loads and other supported sensor data during QC.

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
    └── <AssetId>-Baseline.json
```

The PDF is the human-readable handover document. The JSON is the compact machine-readable record used later by the company-side archive/Excel process.

The PDF is exactly two A4 pages:

- **Page 1:** assembled hardware identity/specifications;
- **Page 2:** benchmark/burn-in result, validation status, Hardware Identity SHA-256 and Manifest SHA-256.

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

- **Asset ID:** administrative identity of the physical PC/case.
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
7. connect the company USB and manually copy the PDF + Baseline JSON;
8. transfer the machine-readable values into the protected master Excel/archive.

Cross-PC duplicate-serial detection and long-term baseline comparison belong to that company-side archive, not to a persistent database on the delivered PC.

## Source / development

Normal operators use only `SitecQC.exe`. Repository scripts such as `Start-SitecQC.ps1`, `Invoke-SitecQC.ps1`, and dependency tooling are retained for development, CI and troubleshooting.

GitHub Actions validates PowerShell 5.1 syntax, JSON, XAML, runtime smoke tests, HWID behavior, reporting and the self-contained Windows x64 package before publishing the `SitecQC-Windows-x64` artifact.

## Documentation

- [`docs/BaselineQC-Workflow.md`](docs/BaselineQC-Workflow.md) — exact production/handover sequence
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — production operations and troubleshooting policy
- [`docs/HWID-v2.md`](docs/HWID-v2.md) — OS-independent hardware identity definition
- [`docs/EVIDENCE-INTEGRITY.md`](docs/EVIDENCE-INTEGRITY.md) — HWID, manifest hash and signature model
- [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) — third-party components
