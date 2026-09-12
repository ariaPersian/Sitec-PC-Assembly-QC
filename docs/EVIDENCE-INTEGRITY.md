# Evidence integrity model

SitecQC v3.8 keeps separate concepts for **hardware identity**, **run-document integrity**, and **physical tamper evidence**. They must not be treated as the same identifier.

## 1. Asset ID

Asset ID answers: **which physical PC/case is this in the organization's process?**

It is an administrative identifier used in the PDF, Baseline JSON and handover process. It is not part of `SITEC-HWID-V2`.

Changing only the Asset ID must not change the hardware identity hash.

## 2. Tamper seal #1

Tamper seal #1 answers: **which physical seal was applied at handover?**

The GUI initially mirrors Asset ID into Tamper seal #1 because that matches the current assembly process, but the operator may overwrite the seal value when necessary.

The seal remains recorded evidence, but it is not part of `SITEC-HWID-V2`. Replacing a seal after authorized service must not falsely imply that the serialized hardware changed.

## 3. Hardware Identity SHA-256

`Hardware Identity SHA-256` answers: **are the serialized core hardware components still the same?**

Schema: `SITEC-HWID-V2`.

Canonical identity inputs are hardware-only:

- SMBIOS System UUID, when available;
- motherboard serial number;
- CPU Full ATPO;
- PSU serial number;
- RAM module serial numbers, normalized and sorted;
- internal storage serial numbers that match the configured BOM, normalized and sorted.

The following are intentionally excluded:

- Windows installation/version/build;
- Asset ID;
- tamper-seal value;
- BIOS version;
- drivers;
- benchmark/burn-in values;
- temperature and sensor readings;
- SSD wear/health and power-on hours;
- timestamps;
- disk free space;
- MAC/network state;
- attached USB/removable devices.

Therefore:

- reinstalling or replacing Windows -> **same HWID**;
- changing drivers/BIOS version -> **same HWID**;
- changing only Asset ID or seal -> **same HWID**;
- connecting/disconnecting USB storage -> **same HWID**;
- replacing motherboard/CPU/RAM/internal SSD/NVMe/PSU with a different serialized unit -> **different HWID**.

Canonical text is normalized to uppercase with whitespace removed, joined with LF, encoded as UTF-8 without BOM, then hashed with SHA-256.

See `docs/HWID-v2.md` for the canonical definition.

## 4. Manifest SHA-256

`Manifest SHA-256` answers: **has the exact evidence document for this QC run changed?**

It is the SHA-256 of the machine-readable QC manifest produced internally during the run.

Unlike HWID, the manifest contains run-specific evidence such as timestamps, validation state, benchmark results, temperatures, utilization and WHEA findings. Therefore its hash will normally differ between two separate QC runs even on unchanged hardware.

This is expected behavior:

```text
Same PC, same serialized hardware
HWID:       SAME
Manifest:   DIFFERENT per run
```

## 5. Digital signature

SHA-256 is a digest; by itself it does not prove who created the evidence if both the evidence and the expected hash can be replaced.

SitecQC supports RSA/SHA-256 evidence signing and immediate verification. The runtime signing implementation can use one-time self-signed signing material so the private key is not retained on the delivered PC.

Digital signing and hashing protect different properties:

- hash -> detects a change relative to a known expected digest;
- digital signature -> verifies that the exact signed bytes correspond to the public certificate/key used at creation time.

For long-term organizational evidence, retain the original PDF/Baseline JSON and relevant hashes/signature metadata in the company-held archive/master records. Do not treat the customer-side Windows installation as the authoritative archive.

## 6. Durable production evidence in v3.8

The customer-facing/local durable output is intentionally compact:

```text
C:\BaselineQC\Output\
├── <AssetId>-QC-Certificate.pdf
└── <AssetId>-Baseline.json
```

The Baseline JSON is the machine-readable transfer record and includes the identifiers needed for later fleet/archive processing, including the HWID and manifest hash.

Detailed runtime files such as benchmark XML, verbose logs, HTML, manifest work files, signature work files and sensor traces are transient under `%TEMP%` and are cleaned after the run. Failed runs may retain one `LastFailure.zip` for troubleshooting.

## 7. Company-side archive

After SitecQC is closed, connect the company archive USB and manually copy the PDF and Baseline JSON. The protected company archive/master Excel process is responsible for long-term evidence such as:

- original Asset ID and seal;
- component serials;
- Hardware Identity SHA-256;
- Manifest SHA-256;
- printed/customer-approved PDF;
- duplicate-serial checks across all 180 systems;
- later comparison when a system is returned for inspection.

This design deliberately survives a customer reinstalling Windows or formatting/replacing the system drive, because the authoritative baseline is retained by the company.
