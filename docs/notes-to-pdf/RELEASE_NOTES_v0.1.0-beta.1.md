# Apple Notes Exporter — Notes to PDF v0.1.0-beta.1

This is a public beta of the Notes-to-PDF workflow in the SimoGatti04 fork of Apple Notes Exporter. It is an early release with known PDF-reader and text-fidelity limitations. Do not treat it as a lossless conversion or as a backup of your Apple Notes library.

## What is included

- Select one or more notes; each selected note is exported as its own PDF.
- Choose the **Faithful** or **Study** PDF layout.
- Preview a PDF before exporting and choose whether PDFs attached to a note are shown as a compact preview or as a compact filename reference.
- Preserve the original attached PDF as an embedded file when it is available and authorized. Attached pages are not appended to the note's page sequence.
- Choose whether exported files are kept together or organized like their source notes.

## System requirements and verification

- The beta was built for Apple Silicon (`arm64`) and was exercised on **macOS 27.0.1**.
- Compatibility with earlier macOS releases has not been verified. A build-time deployment-target override is not a compatibility guarantee.
- The app reads Apple Notes data locally. Grant the app **Full Disk Access** in System Settings only if you choose to use the Notes-reading feature. No Notes library was included in this release package.

## Install

1. Download `Apple-Notes-Exporter-v0.1.0-beta.1.dmg` from the GitHub prerelease.
2. Verify its SHA-256 against the accompanying `.sha256` checksum file (or the hash shown in the release description). In Terminal, run `shasum -a 256 -c Apple-Notes-Exporter-v0.1.0-beta.1.dmg.sha256` from the folder containing both files.
3. Open the DMG and drag **Apple Notes Exporter.app** to **Applications**. Eject the mounted image after copying.
4. The app is ad-hoc signed and is not notarized. macOS may show a first-open warning. Apple requires a Developer ID signature for notarization; this beta does not have one. If, after verifying the checksum, you still choose to open it, use the per-app **Open Anyway** control in System Settings → Privacy & Security. This creates an exception for this app only. Do not disable Gatekeeper or System Integrity Protection globally. See [Apple's current instructions](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).
5. If you use Notes access, enable Full Disk Access for the installed app in System Settings. macOS may require quitting and reopening the app after changing this permission.

## Known limitations

1. Some emoji render visibly but may be absent from text copied or extracted from the PDF.
2. Preview and PDFKit may reorder portions of copied text; visual appearance and extracted text order can differ.
3. Some multiline Monostile blocks may not preserve Apple Notes' original visual block boundaries perfectly.
4. Embedded PDF files are not exposed for opening or extraction by every PDF reader. On the tested system, Preview displayed the note PDF but did not expose an embedded-file extraction action; use a compatible reader if you need to retrieve an embedded attachment.
5. Cancelling while AppKit is already handling a PDF print operation may not stop that operation immediately.
6. PDF fidelity, attachment access, and behavior across real-world notes vary; export failures and unsupported content should be reviewed before relying on the output.

## Validation scope

Automated tests and synthetic UI fixtures are the basis of the beta checks. They do not read personal notes. A successful automated or synthetic test does not establish compatibility with every Notes database, PDF reader, or macOS release. The release description records the exact checks actually completed for this build.

## License and attribution

This fork remains licensed under **GNU General Public License v3.0 or later (GPL-3.0-or-later)**. It is based on [apple-notes-exporter](https://github.com/kzaremski/apple-notes-exporter), originally built by **Konstantin Zaremski**. See `LICENSE` and `CONTRIBUTORS.txt` in the source repository for the full license and attribution history.
