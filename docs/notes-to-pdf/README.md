# Notes to PDF — project brief

Status: **P3 implementation checkpoint — implementation verified with reader/UI limitations** on local branch `codex/notes-pdf-integration`; not pushed, merged to `main`, released, or distributed. See [the integration and validation report](INTEGRATION_REPORT.md) for the P2/P2.1/P3 evidence and remaining gates. Fork of [kzaremski/apple-notes-exporter](https://github.com/kzaremski/apple-notes-exporter), GPL-3.0-or-later. Base inspected: `baa676108c8baa427450d624ffad4c41884eaeb9` (2026-10-22).

## Current implementation checkpoint
- One or more selected notes can be exported as separate, flat, non-overwriting PDFs in the chosen folder; the files are not merged. The note checklist selection is independent from row focus and is retained by note identity while browsing/searching.
- **Study** is the default PDF profile; **Faithful** is selectable and persisted. Older saved configurations decode with Study as the default.
- The app PDF route uses the Notes-aware parser and PDF styling renderer. PDF attachments have two user-selectable modes, independent of Faithful/Study: **Preview + embed** (default) renders a compact first-page preview and embeds the original PDF bytes; **Embed only** renders an icon/name reference without generating a preview. Neither mode appends attachment pages to the note PDF. Ownership checks, size limits, private staging, collision-safe atomic delivery, byte-preserving extraction checks, and explicit partial/failure diagnostics apply. On macOS 27.0.1, Preview opened and rendered a 2-page synthetic note PDF but its observed UI exposed no embedded-file list or extraction action; see the integration report for the reader limitation.
- Supported inline image content is rendered into the standalone PDF where available. Other unsupported file/gallery content is still reported as incomplete rather than linked to temporary staging paths. CLI/MCP and other existing format paths remain outside this app UI integration.
- The explicit-project launcher is `scripts/run-integration-app.sh`; it uses isolated DerivedData and a command-line macOS 13.0 diagnostic override without changing the permanent deployment target. The cause of the stale UI from Xcode's ⌘R has not been established.
- Synthetic validation includes focused PDF-attachment regressions for both attachment modes and both style profiles. The complete app/unit run has one unrelated ZIP modification-time failure; the UI-test runner did not bootstrap. Preview opened the writer-only sample, but app-generated card rendering in Preview and the interactive export UI remain unverified. Poppler listed and extracted the embedded original byte-for-byte; it is a command-line reader toolchain, not a second graphical viewer. This is not full release acceptance; Monostile block-boundary reconstruction (F2/P2.2-E) remains open.

## Goal
An entirely local macOS SwiftUI app to select one or more Apple Notes without manually exporting Markdown, and produce legible, portable, attractive PDF documents. Preserve all original text and meaningful formatting, inline images/tables, attachments and supported links; never mutate the original Apple Notes library.

## Experience
- Search notes by title, independently of folder hierarchy; browse accounts/folders and select single/multiple notes with correct partial-selection states.
- One selected note -> user-chosen `Note name.pdf` by default, **no account/folder tree**. Multiple notes -> individually named PDFs or a combined PDF (combined is later phase). Existing mirrored-tree backup remains available as an advanced/legacy mode if retained.
- Two layouts: **Faithful** (retain Apple Notes semantics, monostyle and highlights) and **Study** (consistent typography, usable margins, centered proportional images, controlled page breaks). Neither rewrites the user's words.
- A4 as locale-appropriate default; controls for size, margins, page format, and the two PDF-attachment modes. Preview and clear export report (including partial failures).
- Offline by default. Local Notes data must have been synced/downloaded. External URL targets may require internet when opened; no automatic crawling/downloading of links.

## Attachment policy
- JPG/JPEG/PNG/HEIC and Apple sketches/scans: represent inline near original location, fit the printable page, never stretch; original optional when accessible.
- Native Notes tables: semantic/reflowable table when data permits; explicit warning on failed parse, not silent omission.
- PDF attachments in the standalone PDF route: select **Preview + embed** (default) or **Embed only** before export. Both preserve the original bytes as a document-level embedded file when available and authorized, retain the attachment reference at its note position, and keep the note page count independent of the attachment page count. No sibling ZIP is created by this single-PDF workflow.
- Other file attachments and Notes galleries: show a meaningful compact reference where possible; unsupported originals remain explicitly incomplete rather than linked to temporary staging paths.
- Internal note links: link to exported target when available; otherwise retain a safe/original link if possible, without inventing paths.
- Web links remain clickable. File and note links must not silently become broken.
- Missing, locked, corrupt, oversized, or unembeddable attachments: report the problem and mark the export partial or failed; do not call it fully complete.
- Embedded-file handling varies by PDF reader. qpdf and Poppler extraction were tested locally; Preview.app opened/rendered the note but did not expose embedded-file controls in the observed UI. Poppler is the independent command-line reader toolchain; no second graphical reader was tested. See the integration report for exact evidence and reader references.

## Safety and privacy
- Read-only source access; never write to the Apple Notes database. Temporary artifacts in a dedicated owned directory, lifecycle-cleaned after verified delivery; safe recovery after crash.
- No private user notes, screenshots, identifying note metadata or attachments in Git, test fixtures, bug reports, CI artifacts or agent prompts. Use synthetic fixtures in Git; real notes only as local/manual validation data, never committed.
- Do not change unrelated CLI, MCP, sync and other exporters by default. Existing behavior is a compatibility constraint.

## Evidence and release gates
- Static inspection does not prove runtime support. Every feature needs targeted tests, compile/build evidence and a manual macOS Notes-to-PDF acceptance test before a release claim.
- First useful milestone: one selected note -> one PDF at exactly the requested path, with correct Monostyle, readable typography, proportional images and explicit attachment failure reporting.
- Next milestones: attachments as self-contained PDF/package, cross-note link fidelity, multi-note output, UI preview, broader Notes content fixtures.

See [architecture contracts](ARCHITECTURE.md), [parallel plan](PARALLEL_PLAN.md), and [manual agent prompts](AGENT_PROMPTS.md).
