# Evidence integrity model

SITEC QC keeps three related but distinct integrity signals.

## Hardware Identity SHA-256

`Hardware Identity SHA-256` answers: **is this still the same assembled PC identity?**

The canonical identity uses stable identifiers only:

- Asset ID
- System UUID
- motherboard serial
- CPU full ATPO
- PSU serial
- tamper seal serial(s)
- RAM module serial(s), sorted
- expected internal storage serial(s), sorted

Volatile values are intentionally excluded, including free disk space, temperature, SSD wear, benchmark scores, CPU frequency, Windows/driver versions, timestamps, and network state.

The canonical UTF-8/LF text is written to `hardware-identity.txt`; its actual file SHA-256 must equal the value printed in `hardware-identity.sha256` and the customer PDF.

## Manifest SHA-256

`Manifest SHA-256` answers: **has the exact evidence document for this QC run changed?**

It is the SHA-256 of `hardware-qc-manifest.json`. The manifest intentionally contains run-specific data such as benchmark results, timestamps, temperatures, WHEA findings, validation state and other evidence, so its hash normally changes between separate QC runs even when the hardware identity is unchanged.

## Digital signature

SHA-256 alone detects change only when the expected hash is retained somewhere trustworthy. SITEC QC additionally signs both `hardware-qc-manifest.json` and `hardware-identity.txt` with RSA/SHA-256.

Default production mode is `EphemeralSelfSigned`:

1. a one-time, non-exportable RSA private key is created automatically;
2. the manifest and hardware identity are signed;
3. signatures are verified immediately;
4. the public certificate is saved as `evidence-signing.cer`;
5. the private key/certificate entry is deleted from the Windows certificate store.

This prevents the same one-time private key from being reused later to re-sign modified evidence. The exported public certificate can verify the original signatures indefinitely at the cryptographic level.

For third-party organizational trust, retain the original PDF/evidence package or its hashes/certificate thumbprint in a protected central archive. A self-signed certificate proves integrity relative to its own public key; it does not by itself establish a public CA-backed corporate identity.

Generated evidence includes:

- `hardware-qc-manifest.json`
- `hardware-qc-manifest.sha256`
- `hardware-qc-manifest.json.sig`
- `hardware-identity.txt`
- `hardware-identity.sha256`
- `hardware-identity.txt.sig`
- `evidence-signing.cer`
- `signature-verification.json`
- `QC-Certificate.pdf`
