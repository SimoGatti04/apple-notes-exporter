# Apple Notes Exporter

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](LICENSE)
[![macOS 27.0.1 tested](https://img.shields.io/badge/macOS-27.0.1%20tested-brightgreen.svg)](https://www.apple.com/macos/)
[![Latest release](https://img.shields.io/github/v/release/SimoGatti04/apple-notes-exporter?include_prereleases)](https://github.com/SimoGatti04/apple-notes-exporter/releases)
[![Downloads](https://img.shields.io/github/downloads/SimoGatti04/apple-notes-exporter/total)](https://github.com/SimoGatti04/apple-notes-exporter/releases)

**Export Apple Notes to customizable PDFs with live preview, multiple layouts, and embedded PDF attachments.** Free and open source for macOS.

This fork's first public beta focuses on the Notes-to-PDF workflow. It is experimental: review exported files before relying on them, and do not treat the app as a lossless conversion or a backup of your Notes library.

## Preview

> **Screenshot placeholder:** a current screenshot has not been published yet. A future image will be captured from the Beta UI using synthetic notes only; the historical v2.1 screenshot is intentionally not presented as the current app.

<!-- Add a newly captured screenshot of the Beta UI here only after confirming that it contains synthetic, non-personal data. -->

## What you can do

- Select one or more notes; export each selected note as its own PDF.
- Choose between **Faithful** and **Study** layouts.
- Preview the PDF before exporting.
- Keep exported PDFs together or organize them like their source notes.
- Choose how a PDF attachment appears in the note PDF while preserving the original as an embedded file where access and source bytes permit.
- Use the existing Apple Notes Exporter project, which also retains its upstream export tools and formats.

## Download

The current download is the experimental **[v0.1.0-beta.1 prerelease](https://github.com/SimoGatti04/apple-notes-exporter/releases/tag/v0.1.0-beta.1)**. Download the disk image and its `.sha256` checksum from the release assets. The [releases page](https://github.com/SimoGatti04/apple-notes-exporter/releases) lists all published versions.

## Install on macOS

1. Download `Apple-Notes-Exporter-v0.1.0-beta.1.dmg` and its checksum file from the prerelease assets.
2. In Terminal, from the folder containing both files, verify the download with:

   ```sh
   shasum -a 256 -c Apple-Notes-Exporter-v0.1.0-beta.1.dmg.sha256
   ```

3. Open the disk image and drag **Apple Notes Exporter.app** to **Applications**.
4. Eject the disk image after copying the app.

## First launch and Gatekeeper

This beta is signed ad hoc. It does **not** have a Developer ID signature and is **not notarized**. macOS may therefore show a security warning. After verifying the checksum, if you decide to continue, use macOS's per-app **Open Anyway** control in **System Settings → Privacy & Security**. Do not disable Gatekeeper or System Integrity Protection globally. See [Apple's instructions for opening an app that has not been notarized](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).

## Apple Notes permission

The Notes-reading workflow accesses the local Notes database. macOS may require **Full Disk Access** for Apple Notes Exporter. Grant it only if you choose to use this feature, and quit and reopen the app after changing the permission. The release package contains no Notes library or user notes.

## PDF layouts

- **Faithful** aims to stay closer to the source note's appearance.
- **Study** uses a more spacious, study-oriented presentation and is the default.

Neither profile promises lossless reproduction of every Apple Notes style or perfect PDF text extraction. The selected layout is saved as an app preference.

## Preview and multiple notes

Select one or more notes in the checklist and preview the PDF before export. A multi-note export creates a separate PDF for each selected note; it does not combine the notes into one PDF. The selection is independent of row focus and is retained by note identity while browsing and searching.

## PDF attachments

Choose one of two attachment display modes before exporting; they are independent of Faithful and Study:

- **Preview + embed** (default): show a compact preview card and filename at the attachment's position, and embed the original PDF where its bytes are available and authorized.
- **Embed only**: show a compact icon and filename, without generating a preview, while embedding the original PDF under the same availability and authorization conditions.

Attachment pages are **not** appended to the note PDF. The exported note remains a standalone PDF. Whether a reader exposes embedded files for opening or extraction varies; test the reader you intend to use. On the tested system, Preview displayed the note PDF but did not expose an embedded-file list or extraction action.

## Output organization

Choose **All together** to put exported PDFs in one destination folder, or **Like in Notes** to reproduce the source folder organization. With multiple selected notes, each note remains a separate PDF in the selected organization.

## Requirements and verified compatibility

- The app is built for Apple Silicon (`arm64`).
- The only verified system for this beta is **macOS 27.0.1 on Apple Silicon**.
- The app target in Xcode is macOS 11.0, but a deployment target is a build setting—not evidence that the app works on that macOS version. Earlier releases are not claimed as compatible.
- The release is ad-hoc signed and not notarized; read the Gatekeeper note above before installing.

## Known limitations and validation status

- Some emoji may appear visually but be absent from text copied or extracted from the PDF; PDFKit and Preview can also produce reordered copied text.
- Some multiline **Monostile** content may be fragmented rather than preserving the original block boundaries.
- Opening or extracting an embedded PDF depends on the reader; Preview did not expose an extraction action in the test performed.
- Cancelling while AppKit is already handling a blocked print operation may not stop it immediately.
- Real-world Notes databases, unsupported content, PDF rendering, and attachment access can vary. Review the results before relying on them.
- The Release UI check for exporting two notes with **All together** directly to a chosen destination was **not run**.
- The Release UI check for embedding and extracting an attached PDF was **not run**.
- Those two UI checks were explicitly accepted as residual risks for this experimental beta; they are not PASS results. Automated tests and synthetic fixtures do not substitute for them.

See the complete [v0.1.0-beta.1 release notes](docs/notes-to-pdf/RELEASE_NOTES_v0.1.0-beta.1.md) and [post-release roadmap](docs/notes-to-pdf/ROADMAP.md) for details.

## Existing project and technical documentation

This fork builds on the original Apple Notes Exporter. The pre-fork README and its historical screenshots are retained in the [legacy documentation archive](docs/legacy/README-upstream-v2.1.md); those descriptions do not describe the Notes-to-PDF beta.

For implementation history, architecture, release verification, and contributor guidance, see:

- [Notes-to-PDF project brief](docs/notes-to-pdf/README.md)
- [Integration and validation report](docs/notes-to-pdf/INTEGRATION_REPORT.md) — historical checkpoint plus a post-release status note
- [Architecture notes](docs/notes-to-pdf/ARCHITECTURE.md)
- [Contributor guide](CONTRIBUTING.md)

## License, credits, and upstream

This fork is licensed under **GPL-3.0-or-later**. It is based on [apple-notes-exporter](https://github.com/kzaremski/apple-notes-exporter), originally created by **Konstantin Zaremski**. Copyright notices and the full attribution history remain in [`LICENSE`](LICENSE) and [`CONTRIBUTORS.txt`](CONTRIBUTORS.txt). The project name remains `SimoGatti04/apple-notes-exporter`; no repository rename is part of this checkpoint.
