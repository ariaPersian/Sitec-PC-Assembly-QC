# Third-party notices

Sitec PC Assembly QC is an orchestration/reporting project. Source/developer runs can obtain third-party components from their official release locations. The GitHub Actions production packaging job also downloads the approved upstream binaries and embeds them unchanged in the self-contained operator package so the production operator does not need a separate dependency-install step.

## Microsoft DiskSpd
- Project: https://github.com/microsoft/diskspd
- License: MIT
- Purpose: storage load generation and performance measurement.
- Packaging: the Windows x64 executable is obtained from the official Microsoft GitHub release during CI and included in the embedded production payload. Preserve the upstream license/copyright terms when redistributing the production package.

## LibreHardwareMonitor
- Project: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
- License: MPL-2.0 for the main project; see upstream THIRD-PARTY-LICENSES for components under other terms.
- Purpose: temperature, load, clock, fan and voltage telemetry when supported by the machine.
- Packaging: release files are obtained from the official upstream GitHub release during CI and included in the embedded production payload. Upstream license and third-party notices remain applicable.

## Windows System Assessment Tool (WinSAT)
WinSAT is supplied by Microsoft with Windows. This project invokes the installed executable and does not redistribute it.

## PassMark BurnInTest
PassMark BurnInTest is proprietary third-party software and is not bundled. Reports produced by a separately licensed installation may be retained as supporting evidence.
