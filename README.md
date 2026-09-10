# Sitec PC Assembly QC

Production-oriented Windows QC application for **hardware inventory, assembly verification, benchmark/stress testing, WHEA error capture, evidence preservation, and customer QC certificates**.

The project targets batch assembly work such as the current 180-PC build and is designed around one principle: **the operator should enter nothing that Windows, SMBIOS, the BOM profile, or a scanner can provide automatically.**

## Operator workflow

The production artifact is a single self-contained Windows executable:

```text
SitecQC.exe
```

The operator runs only this file. It elevates itself, extracts its internal application payload under ProgramData, includes the approved DiskSpd and LibreHardwareMonitor payload used by the build, opens the QC GUI, detects hardware automatically, assigns a persistent Asset ID automatically when no physical asset label has been supplied, and runs the complete QC workflow.

The PowerShell files and dependency installer remain in the repository for development/support, but they are not part of the normal operator procedure.

## What is automatic

The following are collected without operator input when the platform exposes them:

- motherboard manufacturer/model/serial
- CPU model, cores, threads, socket, processor ID
- RAM slot/manufacturer/part number/serial/capacity/type/speed/voltage
- SSD/NVMe model/serial/firmware/capacity/bus/health and reliability counters when exposed
- BIOS version/date/SMBIOS version
- GPU and network inventory
- Windows version/build
- PnP error state
- System UUID
- SMBIOS chassis serial and SMBIOS asset tag when the firmware provides meaningful values
- operator name from the current Windows account
- case model, PSU model and CPU-cooler model from the selected versioned BOM profile

## Physical-only identifiers

Some identity evidence is not available through ordinary Windows hardware enumeration and therefore must come from a physical label or a controlled assembly process:

- **PSU serial** — scan the PSU/box serial or barcode. The current GREEN GP700A-GED V3.1 is treated as a conventional ATX PSU with no software identity channel exposed to Windows.
- **CPU ATPO** — scan Intel's full ATPO serial from the processor 2D matrix or the boxed-processor label before the cooler hides the processor markings.
- **Tamper seal IDs** — scan serialized tamper-evident seals. Seal #2 is optional in the default profile.

USB barcode/2D scanners normally behave as keyboard devices. The GUI is scanner-oriented and moves PSU serial → CPU ATPO → Seal #1 → Seal #2 when the scanner sends Enter. No typing is expected.

The CPU cooler **model is not an operator field** when the batch uses one approved cooler: configure it once in `profiles/B760-14700K-990PRO.json` as `CpuCoolerModel`. If it is left empty, the optional field is omitted from the customer report rather than shown blank.

## Asset ID

Asset ID is a SITEC asset identity, not a CPU/SSD property. The application automatically creates and persists one on first use, preferring a meaningful SMBIOS chassis asset tag when present and otherwise deriving a stable initial token from the SMBIOS System UUID. The operator may overwrite it by scanning an existing physical asset label if the organization already has its own numbering scheme.

For strict human-readable sequential IDs such as `PC-001` … `PC-180` across multiple simultaneously tested machines, use a shared central data/assignment service or preprinted serialized asset labels. A purely local machine cannot safely allocate a fleet-wide sequence without coordination.

## QC and benchmark stack

- Expected-BOM validation
- WinSAT CPU and memory assessment
- Sitec CPU stress workload
- deterministic memory verification
- Microsoft DiskSpd sequential read/write and 4K random-read storage tests
- Windows WHEA hardware-error capture during the QC window
- LibreHardwareMonitor sensor sampling when supported
- optional PassMark/BurnInTest evidence import
- fleet duplicate-serial detection
- baseline/tamper comparison
- SHA-256 evidence hashing and optional RSA signing

The benchmark architecture remains modular. Additional engines such as Phoronix Test Suite can be integrated as an extended adapter without changing the hardware manifest/report schema; core production QC does not depend on an external online benchmark service.

## Reports

Each run produces a merged machine-readable manifest plus customer HTML/PDF evidence. The customer report is **data-driven**: optional fields, storage reliability counters, sensor values, PassMark evidence, enclosure values, and other sections are rendered only when actual data exists. Required-but-missing identity evidence is shown as `Missing` in validation because that absence is itself a QC failure.

Default data root:

```text
C:\SitecQC-Data
```

## Source/developer launch

For repository development only, the application can still be started from source with:

```powershell
.\Start-SitecQC.ps1
```

Missing dependencies are now prepared automatically. `tools\Install-Dependencies.ps1` is retained for maintenance and explicit dependency refreshes, not as an operator step.

## CI / production package

GitHub Actions now performs:

1. Windows PowerShell 5.1 parse validation
2. JSON validation
3. XAML load validation
4. runtime smoke tests for BOM/benchmark/serial validation
5. creation of an offline embedded payload containing the approved DiskSpd and LibreHardwareMonitor binaries
6. publication of a self-contained Windows x64 `SitecQC.exe` artifact

## Evidence integrity

SHA-256 provides file-integrity evidence. For stronger authenticity, configure the existing RSA/SHA-256 signing support so manifests are digitally signed in addition to being hashed.

See `docs/OPERATIONS.md` for production operations and `THIRD-PARTY-NOTICES.md` for third-party components.
