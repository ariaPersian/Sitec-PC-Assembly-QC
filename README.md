# Sitec PC Assembly QC

Production-oriented Windows toolkit for **hardware inventory, assembly verification, benchmark/stress testing, WHEA error capture, evidence preservation, and customer QC certificates**.

The project is designed for batch assembly work such as a fleet of 180 identical PCs. It runs on Windows 10/11 with Windows PowerShell 5.1 and does not require a developer SDK on the test machine.

## What it does

- Collects motherboard, CPU, RAM module, SSD/NVMe, BIOS, GPU, NIC, Windows and PnP state.
- Captures physical-only fields that Windows cannot reliably identify: case, PSU, CPU cooler, CPU ATPO and serialized tamper seals.
- Validates detected hardware against a versioned expected-BOM profile.
- Runs CPU and memory assessments with WinSAT.
- Runs a short CPU stress and deterministic memory verification workload.
- Runs Microsoft DiskSpd for sequential read/write and 4K random-read storage tests when installed.
- Captures WHEA hardware errors that occur during the QC run.
- Optionally samples LibreHardwareMonitor sensors when its DLL is installed by `tools/Install-Dependencies.ps1`.
- Produces one merged JSON manifest plus customer HTML/PDF certificate and SHA-256 evidence hashes.
- Maintains a fleet index and detects duplicate motherboard/RAM/SSD/CPU-ATPO/PSU serials.
- Keeps verbose/internal evidence out of the customer certificate unless it is relevant to PASS/FAIL.

## Quick start

1. Copy or clone this repository to the test machine.
2. Open **Windows PowerShell as Administrator**.
3. Install the optional open-source dependencies once:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\tools\Install-Dependencies.ps1
```

4. Start the operator GUI:

```powershell
.\Start-SitecQC.ps1
```

5. Enter the Asset ID and scan/type the physical identifiers, then click **Run Full QC + Finalize**.

The default output root is `C:\SitecQC-Data`. You can point it at a protected network share by editing `config/appsettings.json` or passing `-DataRoot`.

## Headless / production-line run

```powershell
.\Invoke-SitecQC.ps1 `
  -AssetId PC-001 `
  -ProfileId B760-14700K-990PRO `
  -Operator "Assembly-01" `
  -PsuSerial "PSU123456" `
  -CpuAtpo "ATPO123456" `
  -Cooler "CPU Cooler Model" `
  -Seal1 "SEC-000001" `
  -Seal2 "SEC-000002"
```

The CLI and GUI use the same engine, so operator and automated workflows generate identical manifests.

## Benchmark design

The default production profile intentionally avoids a long 5–10-machine calibration cycle. PASS/FAIL is based on expected hardware BOM match, successful CPU/memory workload completion, deterministic memory verification with zero mismatches, no WHEA hardware errors during the run, storage test success with conservative profile thresholds if DiskSpd is available, and PnP errors when present.

Performance numbers are still stored for later fleet comparison, but the first production run does not need a learned baseline.

## PassMark / BurnInTest

BurnInTest is **not required**. Existing PassMark reports can be attached to a run and referenced by the final manifest. This keeps the Sitec report format independent from PassMark licensing and versions while retaining existing certificates as supporting evidence.

PassMark can be automated with its `/r`, `/c`, `/s` and `/m` production-line switches. Configure it to save reports into the configured report directory and Sitec QC will copy recent results into the current evidence set.

## Important evidence rule

SHA-256 detects changed evidence relative to the stored hash, but a hash alone is not an independent signature. Configure a signing certificate thumbprint in `config/appsettings.json` for RSA/SHA-256 detached manifest signatures.

See `docs/OPERATIONS.md` for the production workflow and `THIRD-PARTY-NOTICES.md` for dependencies.
