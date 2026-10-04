# Asset-scoped QC data root

SitecQC v3.20.0 derives the production QC scratch directory from the confirmed Asset ID.

The configured `DataRoot` value (`C:\SitecQC-Data` by default) is the **base name**, not the final per-run directory.

## Mapping rule

If the Asset ID ends in digits, the trailing numeric portion is appended to the base name without changing leading zeroes:

```text
CASE-001  -> C:\SitecQC-Data-001
CASE-027  -> C:\SitecQC-Data-027
PC-200    -> C:\SitecQC-Data-200
```

If the Asset ID has no trailing numeric portion, the safe complete Asset ID is used:

```text
CASE-TEST -> C:\SitecQC-Data-CASE-TEST
```

## Lifecycle

The folder is transient working data for the active QC run. SitecQC removes stale residue from the same Asset-specific path before starting a new run, then removes the working root after the run has been finalized and the durable evidence has been published.

After a successful verified collector transfer, authoritative local output is intentionally limited to:

```text
C:\BaselineQC\Output\<PC-ID>-QC-Certificate.pdf
```

The authoritative machine-readable record is retained on the collector as `\\10.50.50.20\QC-Results\<PC-ID>\<PC-ID>-Full.json`. If network transfer/verification fails, the local Full JSON is preserved as a fail-safe. The scratch path does not participate in `SITEC-HWID-V2` and is not a replacement for the company-held archive.
