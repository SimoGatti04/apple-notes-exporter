# Notes to PDF — project brief

**Status: public experimental beta published.** The current release is [`v0.1.0-beta.1`](https://github.com/SimoGatti04/apple-notes-exporter/releases/tag/v0.1.0-beta.1), built from commit `61c89d99291b866141c0b2326aa87b303460ad2c`. The source was integrated into `main` by PR #1; the post-merge main reference at this checkpoint is `c10febf5e70d0d8dbb9e65271c769c9916129840`. The beta tag, source commit, and published assets are frozen; this documentation update does not revise them.

This is the Notes-to-PDF workflow in the [SimoGatti04 fork](https://github.com/SimoGatti04/apple-notes-exporter) of [Konstantin Zaremski's upstream project](https://github.com/kzaremski/apple-notes-exporter), under GPL-3.0-or-later. The [integration report](INTEGRATION_REPORT.md) records implementation history; [release notes](RELEASE_NOTES_v0.1.0-beta.1.md) document the user-facing Beta and its validation limits; see the [roadmap](ROADMAP.md) for proposed follow-up work.

## Implemented in the Beta

- Select one or more notes and export each to its own flat, non-overwriting PDF in a chosen destination. Multi-note export does not merge PDFs. Selection is independent of row focus and retained by note identity while browsing/searching.
- Choose **Study** (default) or **Faithful**; the preference persists, and older saved configurations decode with Study as the default.
- Preview the PDF before export.
- Organize output **All together** or **Like in Notes**.
- Choose an attachment presentation independent of the PDF profile: **Preview + embed** (default) or **Embed only**. Neither mode appends attached PDF pages to the note's page sequence. The implementation enforces ownership/size checks, private staging, duplicate-avoidance, atomic delivery, byte-preserving extraction checks, and diagnostics for incomplete or failed attachment handling.
- Render supported inline image content where available; unsupported file/gallery content is reported as incomplete rather than linked to temporary staging.

## Validation facts and limits

- The Beta was verified on macOS 27.0.1 on Apple Silicon. This is the tested environment; the Xcode app deployment target of macOS 11.0 does not establish compatibility on macOS 11 or intermediate releases.
- 206 automated app/unit tests and the offline CLI suite were reported passing for the release checkpoint. Synthetic fixtures were used; personal notes were not used in versioned tests.
- The interactive Release UI check for a two-note **All together** export to a chosen folder was **not run**.
- The interactive Release UI check for embedding and extracting a PDF attachment was **not run**. These two gaps were accepted as residual Beta risks and must not be reported as successful checks.
- Known limitations: emoji/copy-text extraction may be incomplete or reordered; multiline Monostile block boundaries may fragment; PDF readers differ in embedded-file handling; cancellation may not interrupt an already-blocked AppKit print operation.

For installation, permissions, and the full limitation text, see the [root README](../../README.md) and [release notes](RELEASE_NOTES_v0.1.0-beta.1.md).
