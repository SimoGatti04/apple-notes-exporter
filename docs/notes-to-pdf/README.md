# Notes to PDF — project brief

Status: DESIGN APPROVED FOR INITIAL VALIDATION (not implemented or validated). Fork of [kzaremski/apple-notes-exporter](https://github.com/kzaremski/apple-notes-exporter), GPL-3.0-or-later. Base inspected: `baa676108c8baa427450d624ffad4c41884eaeb9` (2026-10-22).

## Goal
An entirely local macOS SwiftUI app to select one or more Apple Notes without manually exporting Markdown, and produce legible, portable, attractive PDF documents. Preserve all original text and meaningful formatting, inline images/tables, attachments and supported links; never mutate the original Apple Notes library.

## Experience
- Search notes by title, independently of folder hierarchy; browse accounts/folders and select single/multiple notes with correct partial-selection states.
- One selected note -> user-chosen `Note name.pdf` by default, **no account/folder tree**. Multiple notes -> individually named PDFs or a combined PDF (combined is later phase). Existing mirrored-tree backup remains available as an advanced/legacy mode if retained.
- Two layouts: **Faithful** (retain Apple Notes semantics, monostyle and highlights) and **Study** (consistent typography, usable margins, centered proportional images, controlled page breaks). Neither rewrites the user's words.
- A4 as locale-appropriate default; controls for size, margins, page format, optional attachment behavior. Preview and clear export report (including partial failures).
- Offline by default. Local Notes data must have been synced/downloaded. External URL targets may require internet when opened; no automatic crawling/downloading of links.

## Attachment policy (target capability, NOT assumed implemented)
- JPG/JPEG/PNG/HEIC and Apple sketches/scans: represent inline near original location, fit the printable page, never stretch; original optional when accessible.
- Native Notes tables: semantic/reflowable table when data permits; explicit warning on failed parse, not silent omission.
- PDF/DOCX/Office/Markdown/other file attachments: show a meaningful inline reference/optional preview; preserve original bytes through PDF embedded file where technically and reader-compatible, or an explicit companion ZIP package. A PDF with links to deleted temporary files is NOT complete.
- Internal note links: link to exported target when available; otherwise retain a safe/original link if possible, without inventing paths.
- Web links remain clickable. File and note links must not silently become broken.
- Missing/unavailable/locked attachments: list them in the report; do not call a partial export fully successful.
- PDF embedded attachments are not universally supported by every viewer; ZIP-with-originals is required as a portable fallback.

## Safety and privacy
- Read-only source access; never write to the Apple Notes database. Temporary artifacts in a dedicated owned directory, lifecycle-cleaned after verified delivery; safe recovery after crash.
- No private user notes, screenshots, identifying note metadata or attachments in Git, test fixtures, bug reports, CI artifacts or agent prompts. Use synthetic fixtures in Git; real notes only as local/manual validation data, never committed.
- Do not change unrelated CLI, MCP, sync and other exporters by default. Existing behavior is a compatibility constraint.

## Evidence and release gates
- Static inspection does not prove runtime support. Every feature needs targeted tests, compile/build evidence and a manual macOS Notes-to-PDF acceptance test before a release claim.
- First useful milestone: one selected note -> one PDF at exactly the requested path, with correct Monostyle, readable typography, proportional images and explicit attachment failure reporting.
- Next milestones: attachments as self-contained PDF/package, cross-note link fidelity, multi-note output, UI preview, broader Notes content fixtures.

See [architecture contracts](ARCHITECTURE.md), [parallel plan](PARALLEL_PLAN.md), and [manual agent prompts](AGENT_PROMPTS.md).
