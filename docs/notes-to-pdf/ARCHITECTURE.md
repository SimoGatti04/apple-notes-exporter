# Architecture and integration contracts

Status: design contract implemented through the P3 app integration checkpoint on `codex/notes-pdf-integration`; see [INTEGRATION_REPORT.md](INTEGRATION_REPORT.md). This is not a claim that every target capability below is implemented or that real-library/UI acceptance is complete. Change shared contracts only via integrator review, not concurrent agent edits.

## Current implementation snapshot
- Parser semantic classes are consumed by the PDF styling helper in the app's standalone PDF path. Monostile multiline block-boundary reconstruction remains an open experimental question (F2/P2.2-E); do not infer original block boundaries from visual line breaks alone.
- The app persists Faithful/Study selection (Study default). Multiple selected notes export as separate flat PDFs through the shared selection/output flow; merge-to-one-PDF is deferred. Visible checklist state is separate from navigation focus.
- CSS owns standalone PDF page margins while AppKit print margins are zero, avoiding the previously identified double-margin path. The explicit-project launcher is `scripts/run-integration-app.sh`; the stale-UI ⌘R root cause remains undetermined.
- Inline images and supported HTML render in place. Verified PDF attachments are split at unique markers and inserted as native PDF pages, retaining source page geometry and vector content where PDFKit permits. Byte/page limits and fail-closed validation are applied; the original PDF is not embedded as an output attachment. Other unsupported file attachments and Notes galleries remain incomplete. See the validation report for evidence and limits.

## Existing source (inspected)
- `Apple Notes Exporter/Apple Notes Exporter/AppleNotesKit/`: C database/attachment parser. Preserve, read-only access.
- `Repository/NotesRepository.swift`: account, folder, note and attachment retrieval; lazy `generateHTML(forNoteId:)`.
- `NoteHTMLGenerator.swift`: parses protobuf attribute runs to HTML. Paragraph style `4` already creates a shaded `<pre>`; `notestore.proto` has `color` and `emphasis_style` fields. Existing `isSameStyle` doesn't compare those attributes: verify and add regression coverage.
- `HTMLAttachmentProcessor.swift`: substitutes inline markers, images, tables, link cards, linked PDF/generic file references.
- `ExportSupport.swift` (`noteHTMLDocument`) contains hardcoded line-height 1.0 and zero margins for text block elements; current CSS limits image height.
- `ViewModels/ExportViewModel.swift`: account/folder tree constructed before export, attachments written beside notes; PDF generated through HtmlToPdf/WebKit.
- `NoteSelectorView.swift` + `ViewModels/NotesViewModel.swift` + `Models/NotesModels.swift`: tree-based selection; folder state can be stale after individual toggles.

## Target boundary
`NotesRepository / decoder → rich semantic HTML + ordered resolved asset references → PDF layout renderer → output planner + attachment packager`. SwiftUI invokes coordinator and renders previews, but should not calculate filesystem layout or parse Notes protobuf. Keep the existing public API/CLI/MCP compatible unless explicitly agreed otherwise.

## First-wave contracts (freeze for parallel work)
1. **Parser output / A → B,C**: retain legal HTML with original text and ordered attachment markers. Represent Monostyle as `<pre class="ane-monostyle">...` (keep safe fallback inline styling if needed). Represent actual detected highlights with `ane-highlight` or an equivalent documented semantic marker. Respect run-specific text color, font, emphasis and alignment only where protobuf meaning is confirmed by fixtures; unknowns must not be invented. Do not throw away unrecognized spans. Do not alter raw user text.
2. **Renderer / B → C**: add a separable PDF document/styling helper within `ExportSupport.swift`, leaving the existing HTML export wrapper backward compatible. Define a pure way to choose `faithful` and `study` CSS profiles and style an HTML body; do not change the export coordinator, application views or configuration storage in B. Preserve intrinsic image proportions; honor margins and printable width/height, prevent avoidable split table rows/figures, favor text-selectable PDFs.
3. **Export planner / C → D**: provide flat single-note PDF output (no account/folder tree and no visible sibling temp folders) while preserving existing mirrored-tree mode. Export-to-folder default for the new UI will be flat; old CLI and MCP semantics must stay unchanged. A destination collision must be handled predictably, not overwritten silently. Surface partial attachment failures separately. Do not pretend external links to staging assets are embedded PDF attachments.
4. **UI / D → C,B**: search and select from `NotesViewModel` using note IDs, not display titles. A single-note toggle must update derived folder tri-state. Design UI to present a flat-PDF default and future Faithful/Study choice, but do not make direct writes to export planner or renderer files; introduce minimal UI-to-existing-API adapters only. In first wave, any choice that is not yet backed by the engine must be visibly disabled, not decorative or inert.
5. **Integrator owns cross-module wiring**: changes to shared `Models/ExportConfiguration.swift`, `Apple Notes Exporter.xcodeproj/project.pbxproj`, coordinator integration between B and C, and final assembly of the new UI with the exporter. No worker may change those shared files without explicit reassignment.
6. **No implicit format support**: full internal PDF file attachments, arbitrary Word/Markdown rendering, OCR and note-to-note PDF jumps require technical validation before being marked supported. Preserve originals through package fallback and report unresolved links.

## First-wave file ownership (exclusive)
- **A parser/fidelity**: `NoteHTMLGenerator.swift`, `notestore.proto` only if essential, `Apple Notes ExporterTests/Apple_Notes_ExporterTests.swift` for isolated tests. Avoid regenerating `notestore.pb.swift` unless necessary and coordinate first.
- **B PDF/styling**: `ExportSupport.swift` for new pure PDF styling functions, `Apple Notes ExporterTests/ExportSupportTests.swift`. Do not edit `NoteHTMLGenerator.swift` or `ExportViewModel.swift`.
- **C flat output/attachments**: `ViewModels/ExportViewModel.swift`, `HTMLAttachmentProcessor.swift`, `Apple Notes ExporterTests/EngineParityTests.swift`. Do not change `ExportSupport.swift`, config model or UI. Any required shared edit: propose a small patch for integrator instead.
- **D GUI/selection**: `AppleNotesExporterView.swift`, `NoteSelectorView.swift`, `ViewModels/NotesViewModel.swift`, `Models/NotesModels.swift` (selection state only), UI test sources. Do not change `ExportViewModel.swift`, config or export support.

## Tests and integration
- First baseline on `main`: record version, `git status`, `git remote -v`, `git worktree list`, `xcodebuild -list`, relevant tests. A test not run must never be labeled PASS.
- Agents work from the same base ref in owned Git worktrees/branches and produce separate commits. Do not cherry-pick unfinished work into another agent's workspace.
- Integrator serially merges A, B, C, D as readiness allows, resolves contracts and wiring, then runs full compilation, export parity tests, deterministic fixtures and real macOS GUI validation.
- Use synthetic test notes for public commits. Keep Auri's or any user's notes private, locally only. Ensure cross-note links, missing attachments, duplicate filenames and failures are negative controls.
