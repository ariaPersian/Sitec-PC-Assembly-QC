# Production BaselineQC workflow

1. Create `C:\BaselineQC` on each assembled PC.
2. Copy `SitecQC.exe` into that folder and run it from the local system drive.
3. Keep USB/removable storage disconnected while hardware discovery and QC/benchmark are running.
4. Confirm/scan Asset ID, PSU serial and CPU Full ATPO. Tamper seal #1 follows Asset ID unless overridden.
5. Run full QC. Output is written to `C:\BaselineQC\Output`.
6. On PASS, keep only:
   - `<AssetId>-QC-Certificate.pdf`
   - `<AssetId>-Baseline.json`
7. Print the two-page PDF. The customer reviews the powered-on PC and printed technical/QC data, then the case is sealed in front of the customer.
8. Close SitecQC. Only then connect the company archive USB and manually copy the PDF and Baseline JSON to the company archive/master Excel workflow.

No durable fleet database, duplicate-serial index or baseline database is stored under ProgramData or elsewhere on the customer PC. Cross-PC duplicate detection and later comparison belong to the company-side archive/Excel process.
