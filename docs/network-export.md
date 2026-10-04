# QC network export

SitecQC automatically transfers the two final QC deliverables to the SMB collector after a run finishes:

- `<PC-ID>-Full.json`
- `<PC-ID>-QC-Certificate.pdf`

`PC-ID` is the confirmed Asset ID entered/scanned in the production UI. Files are stored under `\\10.50.50.20\QC-Results\<PC-ID>\`.

At application startup, the collector test begins automatically after the WPF window is rendered. It runs in a separate PowerShell process and is polled by a lightweight UI timer, so the UI thread is never blocked by SMB/TCP timeouts. The operator can continue entering all QC fields while the test is in progress. The result is appended to the on-screen `[NETWORK]` log and shown in the network status line.

Default collector settings:

- Share: `\\10.50.50.20\QC-Results`
- Username: `QCTransfer`
- Password: `sitec`
- Automatic export: enabled
- Retry count: 3

The UI provides editable **Username** and masked **Password** fields. The default password is `sitec`. **Save settings** stores the current network values, including Password, in the machine-local `SitecQC.local.json` next to `SitecQC.exe`. **Open** and **Test connection** use the Username/Password shown in the UI.

Each file is uploaded to a temporary name, SHA-256 verified on the collector, and only then promoted to its final filename. After both files are verified successfully, SitecQC removes the local Full JSON (and any temporary Baseline JSON) and keeps only `<PC-ID>-QC-Certificate.pdf` on the tested PC.

If the network transfer or verification fails, SitecQC does **not** delete the local machine-readable evidence. The local Full JSON is preserved to prevent data loss, and the network-transfer failure remains separate from the QC PASS/FAIL result.

The **Open** action prepares SMB access for `10.50.50.20` from the Username/Password shown in SitecQC and then launches `\\10.50.50.20\QC-Results\` in Windows Explorer. The operator does not need to type the credentials again in Explorer.

The **Test connection** action verifies TCP/445, SMB access, and actual write/delete permission on the share.


## Credential settings

The temporary QC network defaults are intentionally simple: `QCTransfer` / `sitec`. They are editable in the application and may be saved locally. No additional password-hardening workflow is required for this isolated temporary collector path.
