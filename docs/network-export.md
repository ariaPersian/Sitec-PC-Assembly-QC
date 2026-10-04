# QC network export

SitecQC can automatically copy the two operator-facing QC deliverables to an SMB collector after a run finishes:

- `<AssetId>-Full.json`
- `<AssetId>-QC-Certificate.pdf`

Default collector settings:

- Share: `\\10.50.50.20\QC-Results`
- Account label: `QCTransfer`
- Automatic export: enabled
- Retry count: 3

The application does not embed an SMB password in the public repository or executable settings. Windows supplies the SMB credential from the credential already configured on the production PC. This keeps operators out of the authentication flow without publishing a live password in source control.

Machine-local path/user/auto-export settings are stored in `SitecQC.local.json` next to `SitecQC.exe`.

The application always keeps the local PDF and Full JSON. A failed network export is reported separately and does not change the QC PASS/FAIL result.

The **Test connection** action verifies TCP/445, SMB access, and actual write/delete permission on the share.
