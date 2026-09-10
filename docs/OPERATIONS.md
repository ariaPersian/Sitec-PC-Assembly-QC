# Production Operations Guide

## 1. Production package

Use the GitHub Actions artifact `SitecQC-Windows-x64`, which contains the self-contained `SitecQC.exe` operator application. The production executable embeds the approved application payload plus Microsoft DiskSpd and LibreHardwareMonitor release files prepared by CI.

Normal assembly operators run **only `SitecQC.exe`**. They do not run `tools\Install-Dependencies.ps1`, `Start-SitecQC.ps1`, or other repository scripts. Those files remain for development and support.

The executable requests Administrator elevation, expands its versioned internal payload under `%ProgramData%\SitecQC\App\<version>`, and opens the QC interface. No .NET SDK or separate dependency-install step is required on the production machine.

## 2. Evidence root

The default evidence root is:

```text
C:\SitecQC-Data
```

For stronger evidence retention, a later deployment profile may point `DataRoot` at a restricted network share such as:

```text
\\FILESERVER\QC-Evidence
```

Operators should have only the permissions required to create/write records. Restrict deletion and administrative access where possible and back up the evidence store.

## 3. Automatic identity collection

On startup the application automatically collects the information that Windows/SMBIOS can expose: motherboard, CPU, each RAM module, SSD/NVMe, BIOS, graphics, network, Windows information, System UUID, device errors, storage reliability data when supported, and SMBIOS system-enclosure serial/asset tag when meaningful values exist.

The application also assigns a persistent Asset ID automatically if no physical Asset ID has already been scanned. Priority is:

1. meaningful SMBIOS enclosure asset tag
2. stable token derived from SMBIOS System UUID
3. motherboard serial fallback
4. generated persistent GUID-based token as final fallback

The generated value is persisted under `%ProgramData%\SitecQC\asset-id.txt` so repeated runs on the same assembled PC keep the same identity.

If the organization requires human-readable fleet numbers such as `PC-001` through `PC-180`, use preprinted serialized asset labels or a central coordinated allocator. Scan that label into Asset ID to override the automatic identifier. Do not let multiple isolated PCs independently allocate a shared numeric sequence.

## 4. Physical-only identity capture

Some values do not have a reliable Windows-readable identity channel and must be captured physically:

- **PSU serial:** scan the manufacturer serial/barcode from the PSU or its controlled packaging before/while assembly.
- **CPU ATPO:** scan the Intel processor full ATPO from the processor 2D matrix or boxed-processor label before the cooler hides the processor markings.
- **Tamper seals:** scan the serialized tamper-evident seal IDs when installed. The supplied profile requires Seal #1; Seal #2 is optional.

A USB barcode/2D scanner is preferred over typing. The GUI moves automatically through PSU Serial → CPU ATPO → Seal #1 → Seal #2 when the scanner sends Enter.

The CPU cooler model is **not an operator-entry field** when the batch uses one approved cooler. Configure it once in the expected-BOM profile (`Expected.CpuCoolerModel`). If the value has not yet been supplied, it remains optional and the customer report omits the empty field.

## 5. Normal operator procedure

1. Double-click `SitecQC.exe` and approve UAC.
2. Confirm the automatically detected hardware/Asset ID; scan a preprinted Asset ID only if your fleet uses one.
3. Scan the required physical identifiers shown by the profile (normally PSU Serial, CPU ATPO, Seal #1; optional Seal #2).
4. Click **RUN FULL QC + FINALIZE**.
5. Wait for PASS/FAIL and open/print the generated certificate if needed.

Hardware discovery occurs automatically on application startup; **Refresh Hardware** is only for re-reading the machine after a physical/configuration change.

## 6. QC workload

The production workflow runs expected-BOM validation, WinSAT CPU/memory assessment, CPU stress, deterministic memory verification, DiskSpd storage testing, sensor capture when supported, and WHEA hardware-error capture during the QC window.

DiskSpd targets only its temporary test file and removes it after the workload. The production implementation does not intentionally target a raw physical disk.

The short default workload is designed for production throughput. Duration and thresholds remain versioned configuration so a later validation policy can increase burn-in time without changing the operator procedure.

## 7. PASS/FAIL policy

A normal PASS requires the versioned expected BOM to match, required physical identity fields to be present, duplicate serial checks to pass, CPU/memory workload success, zero deterministic-memory mismatches, zero WHEA hardware errors, and required storage checks to pass.

WinSAT performance thresholds remain advisory where normal Windows/power-state variation can affect the number. DiskSpd thresholds in the supplied i7-14700K/990 PRO profile are intentionally conservative and are intended to catch severe misconfiguration, wrong devices, or major underperformance rather than rank machines.

If the exact production BOM changes, create/update a versioned profile deliberately. Historical manifests keep the profile/version recorded at test time.

## 8. Customer report behavior

The customer HTML/PDF report is data-driven rather than a fixed blank form. Optional properties, columns, and sections are rendered only when actual data exists. Examples include storage reliability counters, sensor measurements, enclosure fields, optional Seal #2, CPU cooler model, and PassMark supporting evidence.

Required identity evidence that is absent is not silently hidden: validation shows it as `Missing` and the QC result fails. The complete machine-readable manifest keeps all collected evidence regardless of whether every field is useful in the customer-facing layout.

## 9. Baseline and tamper verification

The first PASS for an Asset ID creates:

```text
Assets\<AssetId>\Baseline\hardware-qc-manifest.json
```

The worker does not overwrite an existing baseline automatically. Subsequent verification can compare motherboard serial, CPU identity, RAM serial set, storage serial set, BIOS and other captured identity against that baseline. A BIOS change alone does not prove tampering; component serial replacement and broken/mismatched physical seals provide stronger evidence.

The repository's `Verify-SitecQC.ps1` remains an administrative/support tool. A future GUI release can expose baseline verification behind the same `SitecQC.exe` so delivered operators never need a separate script.

## 10. PassMark coexistence and future benchmark adapters

PassMark BurnInTest remains optional supporting evidence. When configured by support/administration, recent matching reports whose filename contains the Asset ID are copied into the run evidence and referenced by the merged report.

Sitec QC remains the authoritative hardware/identity manifest and fleet index. Benchmark engines are adapters behind that workflow; introducing an additional engine such as Phoronix Test Suite must not create a second operator procedure or require the operator to manage separate report paths.

## 11. Evidence integrity

`hashes.sha256` and the manifest SHA-256 provide change detection. For authenticity beyond a mutable hash file, configure the existing RSA/SHA-256 signing capability on an authorized QC environment and protect the signing private key. Do not leave private signing material on PCs after delivery.

## 12. Output per asset

```text
Assets\<AssetId>\
  Baseline\
    hardware-qc-manifest.json
    hardware-qc-manifest.sha256
    [signature/certificate]
  Runs\<AssetId>-YYYYMMDD-HHMMSS\
    hardware-qc-manifest.json
    hardware-qc-manifest.sha256
    QC-Certificate.html
    QC-Certificate.pdf
    hashes.sha256
    result.json
    status.json
    worker.log
    benchmark\winsat\...
    benchmark\diskspd\...
    passmark\...
    photos\...
```

The fleet-level `fleet-runs.csv` and `fleet-serial-index.csv` files support duplicate detection and batch inventory without requiring a separate database server.
