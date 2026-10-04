# QC network export

SitecQC automatically transfers the two final QC deliverables to the SMB collector after a run finishes:

- `<PC-ID>-Full.json`
- `<PC-ID>-QC-Certificate.pdf`

`PC-ID` is the confirmed Asset ID entered/scanned in the production UI. Files are stored under `\\10.50.50.20\QC-Results\<PC-ID>\`.

At application startup, the collector test begins automatically after the WPF window is rendered. It runs in a separate PowerShell process and is polled by a lightweight UI timer, so the UI thread is never blocked by SMB/TCP timeouts. The operator can continue entering all QC fields while the test is in progress. The result is appended to the on-screen `[NETWORK]` log and shown in the network status line.

Default collector settings:

- Share: `\\10.50.50.20\QC-Results`
- Account label: `QCTransfer`
- Automatic export: enabled
- Retry count: 3

The application does not embed an SMB password in the public repository or executable settings. Windows supplies the SMB credential from Windows Credential Manager. The production Windows user must have a stored credential for `10.50.50.20` using account `QCTransfer`; this should be provisioned once during golden-image/post-deploy preparation. After that, the operator is not prompted for a username or password.

Machine-local path/user/auto-export settings are stored in `SitecQC.local.json` next to `SitecQC.exe`.

Each file is uploaded to a temporary name, SHA-256 verified on the collector, and only then promoted to its final filename. After both files are verified successfully, SitecQC removes the local Full JSON (and any temporary Baseline JSON) and keeps only `<PC-ID>-QC-Certificate.pdf` on the tested PC.

If the network transfer or verification fails, SitecQC does **not** delete the local machine-readable evidence. The local Full JSON is preserved to prevent data loss, and the network-transfer failure remains separate from the QC PASS/FAIL result.

The **Open** action checks for an active SMB session or a stored Windows Credential Manager entry for `10.50.50.20` and then launches `\\10.50.50.20\QC-Results\` in Windows Explorer. It does not perform a blocking SMB path probe on the UI thread. Authentication is silent from the operator's perspective because Windows submits the stored `QCTransfer` credential automatically. If no stored credential/session is available, SitecQC reports the problem instead of opening a Windows credential prompt.

The **Test connection** action verifies TCP/445, SMB access, and actual write/delete permission on the share.


## Credential provisioning

Provision the collector credential in the Windows user profile used for QC before production use:

1. Open **Credential Manager** → **Windows Credentials**.
2. Choose **Add a Windows credential**.
3. Internet or network address: `10.50.50.20`.
4. User name: `QCTransfer`.
5. Enter the production QCTransfer password used by the collector laptop.

Do not commit that password to this repository or to `appsettings.json`. For cloned systems, make credential provisioning part of the golden-image/post-deploy process and validate it on at least one deployed clone before scaling out.
