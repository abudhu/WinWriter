# Win11 USB Creator

A small native Swift/AppKit macOS app: choose a Windows ISO, select a USB disk, confirm erasure, authorize immediately, then create the installer. Fast creation is the default; full content verification is opt-in. Live logs, phase progress, and safe cancellation are included. No runtime Homebrew, drivers, installed background service, or network connection is required.

## Run

Download **Win11-USB-Creator.zip** from the [latest release](https://github.com/abudhu/WinWriter/releases/latest), extract it, and open **Win11 USB Creator.app**. The app supports Intel and Apple silicon Macs running macOS 12 or later.

**The current release is Apple Development signed, not notarized.** macOS may block it or require explicit approval to open it; it does not have notarized Developer ID distribution trust.

To build from source, run `/bin/bash scripts/build.sh`, then open `dist/Win11 USB Creator.app`.

1. Choose an official Windows 11 `.iso`.
2. Select an external physical USB disk. The app scans once at launch; click **Refresh** after connecting or disconnecting a disk. It never periodically rescans. The list shows the model, capacity, and device identifier.
3. Click **Create Windows USB**. Confirm the exact disk and approve macOS administrator authorization **before** ISO verification or conversion starts.
4. Leave the disk connected until **Complete — USB created and ejected** appears (or **verified and ejected** with Full Verification enabled).

**Every partition and all data on the selected disk are erased.** Cancellation or an error does not restore previous contents. If a run fails, eject the USB in Finder before disconnecting and recreate it before using it.

The resizable native window groups ISO and USB selection, keeps long filenames compact (hover for the full path), and uses system colors for light/dark appearance. The status panel shows the next step or result; phase progress appears only during creation. The live activity log stays visible and can be copied with **Copy Logs**.

### Optional Full Verification

Click **Fast creation** in the window and select **Full Verification (Slower)**, or use **Win11 USB Creator → Settings → Full Verification (Slower)**. This enables source-image checks, generated split-image integrity tables, SHA-256 readback, and image decompression/checksum verification. The preference is saved and cannot change during a run; the window shows the selected mode. It is **off by default**: normal creation retains disk safeguards, structural/size checks, checked writes, flushes, and safe ejection, without full-content scanning or readback. Splitting remains automatic when FAT32 requires it.

### Permissions

The app requests administrator approval at the start. macOS handles the password; the app never reads or stores it. A one-shot signed formatter waits for preflight, accepts only one erase of the selected disk identity, and exits if the app cancels, fails preflight, or closes. Both peers authenticate kernel-provided identities and code signatures. There is no installed privileged service and no dependency on an expiring password cache. The app uses macOS's in-process AppleScript authorization mechanism rather than launching `osascript`, so the prompt identifies the app.

Existing mounted USB volumes are accessed upfront to request removable-volume privacy approval before lengthy work. If access was denied, open **System Settings → Privacy & Security → Files & Folders → Win11 USB Creator → Removable Volumes**; for source access, reselect the ISO with the chooser. Full Disk Access is not required. macOS may first request removable-volume access after formatting an initially unmounted/unformatted disk. Apple Development signing is not notarization; Apple's unverified-app warning is separate from these permissions.


## Compatibility

- Hosts: macOS 12 Monterey or later, Intel (`x86_64`) and Apple silicon (`arm64`). Both the app and bundled WIM tool are universal binaries. Intel Touch Bar models support Monterey; the installed OS must meet this minimum.
- Targets: Windows UEFI PCs. Use an x64 ISO for x64 PCs or an Arm64 ISO for compatible Windows Arm64 PCs, regardless of which Mac creates the USB.
- This does not enable native Windows boot on Apple silicon Macs, patch Windows requirements, provide Mac/Boot Camp drivers, or promise legacy BIOS boot.
- Media: writable external physical USB disks up to the MBR addressing limit (approximately 2 TiB). USB SSDs are included; check the selected disk carefully. Internal, virtual, non-USB, and running macOS disks are excluded.
- Capacity is checked against the installer contents plus filesystem/split overhead. 8 GB is a general starting point, not a guarantee; current larger ISOs need 16 GB or more.

## Why files, not raw ISO imaging?

Windows installation ISOs are not generally hybrid USB disk images. The app creates an MBR partition map with a FAT32 `WIN11` partition and copies the UEFI installer files without modifying their contents or Microsoft's bootloader signatures.

FAT32 permits a maximum file size of 4,294,967,295 bytes. Oversized `sources/install.wim` is split into `install.swm`, `install2.swm`, etc. with bundled **wimlib 1.14.5**, using 3800 MiB parts. Integrity tables are generated only with Full Verification enabled; a bundled, source-distributed CLI patch exposes wimlib's existing no-integrity flag for fast splitting, including when the source has an integrity table. Windows Setup understands split files without these optional tables. Existing split installers and smaller WIM/ESD installers are supported. Oversized ESD/solid WIM is converted to a local non-solid WIM before erasure; this requires extra local storage. Conversion uses wimlib's CPU-autodetected compression threads. Copying and splitting stay sequential to avoid competing writes to the same USB. Unsupported oversized files, invalid paths, ambiguous payloads, and insufficient capacity fail before erasure.

FAT32 itself can support BIOS or UEFI boot. This app specifically prepares the UEFI path and does not install BIOS boot-sector code; Windows 11's supported hardware requirements specify UEFI. That is distinct from the filesystem's capabilities. WinDiskWriter also automatically splits oversized WIMs using wimlib.

Progress is per phase, not a fabricated overall ETA. Copy/readback and wimlib split/verification/conversion report measured percentages. Split-part integrity-table work holds the overall split percentage while logs show that substep's progress. Short carriage-return-delimited tool updates are streamed immediately. Formatting/mounting remain indeterminate because macOS does not provide reliable byte progress for them.

## Safety and verification

- No free-form device path entry. Disk identity includes the IOKit registry entry ID, not just the recyclable `/dev/diskN` name.
- The authorized formatter rechecks that the same device is a writable external physical USB and not the running macOS disk, both after approval and immediately before erasure. Its command and disk identity are fixed; ISO parsing, conversion, copying, and verification run as the user.
- The ISO and app must not reside on the disk being erased.
- Every mode checks installer structure and capacity, source stability, write errors, split-part numbering/identity/completeness, FAT32 limits, and flushes. Full Verification is not a prerequisite for creating bootable installation media.
- With Full Verification: boot/install WIM contents are verified before formatting; copied files accumulate SHA-256 digests; generated SWM parts include integrity tables.
- With Full Verification: the USB is unmounted/remounted before independent readback. Copied files' sizes and uncached SHA-256 must match the source. Boot/install images then undergo wimlib's integrity-table, metadata, decompression, and content-checksum verification.
- Completion requires successful creation and ejection, plus verification when enabled. Formatting, remounting, and ejection cannot be cancelled. The app prevents ordinary quitting during active work.

Verification checks transfer and image integrity, not ISO publisher authenticity, firmware compatibility, or successful Windows installation. Obtain ISOs from Microsoft and use Microsoft's published download hash where available. Physical disconnection, force-quitting, power loss, or failing hardware can still interrupt a write.

## Build and signing

Requirements: macOS, Xcode/Command Line Tools with Swift 5.9+, and **pkg-config at build time only** (`brew install pkg-config`, or provide `PKG_CONFIG=/absolute/path`).

```sh
/bin/bash scripts/build.sh
swift test
```

The build downloads and checksum-verifies the pinned wimlib source, disables FUSE/NTFS dependencies, statically links libwim into its separate CLI, builds both architectures, and signs the tool before the app. Only Apple system libraries are runtime dependencies. No signing private keys or credentials are copied into the repository or artifacts.

Signing prefers **Developer ID Application**, then **Apple Development**. `SIGN_IDENTITY` can select a certificate explicitly. Apple Development is suitable for local development; it is not notarized public distribution. For Developer ID distribution with an existing Keychain notarization profile:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-profile' /bin/bash scripts/build.sh
```

See [build and distribution details](scripts/BUILDING.txt). The build fails rather than silently switching to ad-hoc signing; ad-hoc is an explicit local-only option.

One universal ZIP serves both Intel and Apple silicon Macs; both the app and bundled WIM tool contain native `x86_64` and `arm64` code. The [Verify release workflow](.github/workflows/verify-release.yml) downloads the exact release assets (including drafts), checks their hashes/signatures and architecture slices, then launches the app and performs a WIM capture/split/verify/extract round trip on separate native Intel and Apple silicon macOS runners. It never authorizes or formats a disk. Release-specific results are recorded in the release notes.

## Distribution and licenses

The application is distributed under the [GNU Affero General Public License v3](LICENSE). Its license is included in the app as `Contents/Resources/Licenses/WinWriter-LICENSE.txt`. The matching application source is available through each release’s tagged source archives. Packaging scripts retain their separate 0BSD notice.

`dist/` contains the app, ZIP, checksums, license notices, build scripts, and wimlib corresponding-source archive. **Distribute the corresponding-source archive and notices alongside the binary ZIP.** The separate wimlib command-line executable is GPL-3.0-or-later; the Swift app does not link libwim. Source rebuilding details are in [scripts/WIMLIB-SOURCE.txt](scripts/WIMLIB-SOURCE.txt).

## Verification exercised

- Physical USB: `Windows11_Client_x64_en-us_26300_9457.iso` was written to the authorized 123.06 GB Ultra USB 3.0 using the native app on Apple silicon. FAT32 formatting, split-image creation, remount, readback/image verification, and safe ejection completed successfully. This first run preceded the progress-display fix and removal of redundant generated-SWM hashing passes.
- Safe disk-image smoke: real WIM capture/splitting onto FAT32, remount, measured progress, SHA-256 readback, and wimlib verification. Deliberate copied-file and SWM corruption were rejected, including after simplifying SWM verification to use wimlib directly.
- Fast/Full Verification smoke: real multi-part WIM writes to FAT32 disk images succeeded in both modes. A source containing an integrity table produced split parts without tables in fast mode; those parts independently passed wimlib verification. Full mode generated tables, passed readback, and rejected same-size copied-file corruption and SWM corruption. A fast-mode receipt could not be presented as fully verified. These synthetic fixtures are not a physical USB timing benchmark.
- Settings: the unchecked default, enabling Full Verification, persistence across relaunch, and restoring fast mode were exercised in the native menu. The upfront app-owned macOS authorization dialog was observed in a no-erase probe; its approval was not supplied, so approved root formatting through the new session remains unverified.
- Formatter IPC smoke: signed peers connected over a real Unix socket, authenticated kernel audit tokens and matching code signatures, rejected an incorrect UID, and exited their wait on disconnect without an erase command. Unit coverage also rejects non-root entry and oversized protocol messages.
- Regression coverage includes FAT32 size boundaries, source mutation, invalid paths, capacity, split-part progress boundaries, and short progress updates delivered before a child process exits.
- Native interface: ISO chooser, physical USB selection, Cancel-default erase confirmation, readable scrolling logs, live copy progress, locked controls, protected quitting during a write, and completion/ejection state exercised.
- Interface redesign: exercised the signed app’s ISO chooser, no-USB creation guard, in-window verification toggle/reset, minimum-size layout, and log copying. A temporary AppKit preview exercised light/dark appearance, long filenames, determinate/indeterminate progress, locked controls, cancellation, fast/full completion, failure, and Cancel-default confirmation. Preview states used synthetic events; no disk was formatted during this UI pass.
- Release `v1.0.0`: the uploaded universal ZIP passed [native Intel x86_64 and Apple silicon arm64 checks](https://github.com/abudhu/WinWriter/actions/runs/40903644775) on hosted macOS 15 runners: hashes/signatures/license, both architecture slices, app main-window launch, and a WIM capture/split/verify/extract round trip with byte-for-byte recovery. No physical USB was formatted by these checks.
- Limits: no PC firmware boot/Windows installation test and no macOS 12 machine available. The intended physical Intel target is a 13-inch 2020 MacBook Pro running Tahoe 26.6.2, which meets the deployment target. Execution on that particular Mac remains unverified. Hosted native architecture checks do not replace a physical USB/PC boot test.

## Research

- [Microsoft: Install Windows from a flash drive](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/install-windows-from-a-usb-flash-drive?view=windows-11) — FAT32 and split `install.swm` installation.
- [wimlib: split](https://wimlib.net/man1/wimsplit.html) — MiB sizing, integrity tables, and indivisible-resource limits.
- [wimlib: verify](https://wimlib.net/man1/wimverify.html) — metadata, resource completeness, decompression, and checksum checks.
- [wimlib releases and source](https://wimlib.net/) — pinned upstream dependency.
- [Microsoft: Windows 11 requirements](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements) — UEFI is a supported-platform requirement, distinct from FAT32's BIOS/UEFI boot capabilities.
- [WinDiskWriter features](https://github.com/TechUnRestricted/windiskwriter#features) — also automatically splits oversized WIMs with wimlib.
- [Apple: Identify your MacBook Pro](https://support.apple.com/en-us/108052) — oldest Intel Touch Bar models support macOS Monterey.
- [Apple: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [color](https://developer.apple.com/design/human-interface-guidelines/color), and [progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) — native controls, hierarchy, adaptive colors, and transient progress.
- [Transmit](https://panic.com/transmit/) — native utility and activity-view visual reference.
