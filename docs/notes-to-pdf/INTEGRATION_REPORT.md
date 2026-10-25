# P2 — Apple Notes Exporter Integration & End-to-End Validation

**Decision: READY WITH LIMITATIONS**
**Date:** 2026-10-23

> **P3-B correction (2026-10-25):** The later user correction supersedes the original §12 P3-B requirement to append attachment pages. The current contract is a single standalone note PDF with compact inline references and the original PDF embedded as a file; attached pages are never added to the note page tree. The P3-B and validation notes below reflect the corrected contract. Earlier P2/P3 statements are historical snapshots.
**Integration branch:** `codex/notes-pdf-integration`
**Integration pre-wiring HEAD:** `d618d785b5a9d45e0dc1eb85f1af20913a6fab88`
**Baseline:** `main` at `e05a858168e9a33d08e3748f0a37547a60f50fa2`
**Final branch commit:** the commit containing this report and its accompanying integration documentation; the final exact HEAD is recorded in the completion handoff.

This is a local integration checkpoint only. No push, merge into `main`, release, or distribution was performed.

## 1. Objective and scope

Integrate the parser, PDF-layout, export-output, and SwiftUI contributions into a coherent first Notes-to-PDF app flow; independently verify their commits and the shared seams; run the app/unit suite, inspect rendered PDF samples, and record unsupported behavior honestly.

All versioned and automated test inputs were synthetic. The tests did not read or export personal Apple Notes. Real-library and interactive UI acceptance were not performed.

## 2. Repository and source verification

The canonical checkout remains clean on `main` at baseline `e05a858168e9a33d08e3748f0a37547a60f50fa2`. The integration worktree is `/Users/gatti/.codex/worktrees/notes-pdf-integration/apple-notes-exporter`, on `codex/notes-pdf-integration`. The four source worktrees were inspected and left untouched; each supplied commit is an ancestor of the integration HEAD above. The tested app/unit tree was that HEAD plus the six application/test-file integration edits listed in §8; documentation was added after the test run, without changing the tested code.

| Area | Source branch | Source commit | Integration merge commit |
|---|---|---|---|
| A — Notes parser and formatting semantics | `codex/notes-parser` | `654f6dde50e66df5bce486f52e6f3f4a504d9bb8` | `34e8cc4` |
| B — PDF profiles and layout | `codex/pdf-layout` | `5ba41a99344a0b04e23fbd1414d9d294201f4e47` | `5c38534` |
| C — flat PDF export and attachment reporting | `codex/export-output` | `77d86d97c4bebcf68cc2526ee38d43d7997b1867` | `6a2d138` |
| D — searchable SwiftUI selection | `codex/notes-ui` | `a43ddeb1515a115520a44b25b137f30254c4a4b2` | `d618d78` |

No merge conflicts remained. The shared `Apple_Notes_ExporterTests.swift` edits from A and D both survive in the integrated tree; additional cross-module tests cover parser-to-renderer and UI-to-export seams. The integration owns the cross-module wiring and `ExportConfiguration` changes.

## 3. Implemented behavior

### App and selection flow
- The SwiftUI flow retains global note search, account/folder navigation, and single/multiple note selection with derived folder selection state.
- Faithful/Study is now an active segmented control, not a decorative “coming soon” card. The selected profile is persisted. A missing profile in older saved configuration decodes to Study.
- A single selected note with PDF format routes to `exportSingleNotePDF`. It writes one PDF directly to the chosen directory, does not construct an account/folder tree, and uses stable collision suffixes instead of silently overwriting an existing PDF.
- For multiple selected notes, the existing output planner remains active and emits one PDF per selected note. It does not claim or attempt to merge them into one PDF. UI copy describes the distinction and which advanced container choices apply.
- The selected profile affects the app's standalone PDF renderer only. The legacy PDF route and non-PDF HTML wrapper remain covered; no CLI/MCP code was changed by the integration wiring.

### PDF rendering and attachment semantics
- The parser's `ane-monostyle`, highlight, alignment, and blockquote semantic classes flow into the PDF styling helper. Parser regressions verify inline style transitions do not unbalance paragraph/list markup or alter plaintext.
- Faithful and Study use separate CSS profiles. Page margins are supplied through CSS and AppKit print margins are zeroed on the styled PDF route, avoiding double application. Text remains selectable; rendering and pagination use WebKit/AppKit.
- Inline raster/image content available to the standalone path is embedded in the PDF. Synthetic tests cover proportional landscape image rendering, tables, colored highlight, Monostyle, page breaks, and multi-page selectable text.
- Missing inline images produce a partial result with an explicit diagnostic and no dead staging link. At the P2 snapshot, PDF/DOCX/Markdown/generic file attachments and Notes galleries were not portable embedded attachments: the PDF showed a descriptive reference and marked the content incomplete. P3 supersedes only the PDF-page inclusion portion of that behavior; non-PDF attachments/galleries remain unsupported, and the source PDF is not embedded as a file. Gallery child images are not all rendered in original order in this route.

## 4. Verification environment and execution

- Xcode 27; macOS 27.0.1 on an arm64 Mac mini.
- Diagnostic deployment target: `MACOSX_DEPLOYMENT_TARGET=13.0`; this was a command-line build setting only and did not change the project's permanent target.
- Code signing was disabled for local build/test.
- All fixtures were generated in test code, including synthetic SQLite note stores and a 240×120 generated image. No private notes, images, or note metadata were added to Git.

### Commands and outcomes

| Check | Outcome | Evidence |
|---|---|---|
| Baseline complete Xcode test action at `e05a858...` | **PASS** — 145 passed, 0 failed, 0 skipped | `/private/tmp/apple-notes-exporter-baseline-derived/Logs/Test/Test-Apple Notes Exporter-2026.10.23_14-26-09-+0200.xcresult` |
| Candidate explicit app build | **PASS** | Xcode build on `My Mac`, arm64, deployment target 13.0, signing disabled |
| Candidate full Xcode test action | **PARTIAL / UI RUNNER ERROR** — 182 passed, 1 failed, 0 skipped (183 total). The only reported failure was `Apple Notes ExporterUITests-Runner` exiting with signal kill before establishing its test connection; bootstrapping never completed. | `/private/tmp/apple-notes-exporter-integration-final-derived/Logs/Test/Integration-Final.xcresult` |
| Candidate app/unit test target without UI target | **PASS** — 182 passed, 0 failed, 0 skipped | `/private/tmp/apple-notes-exporter-integration-final-derived/Logs/Test/Integration-Unit-Only.xcresult` |
| PDF visual rendering test | **PASS** — Faithful and Study each produced two pages; all four TIFF attachments were opened and visually inspected | `/private/tmp/apple-notes-exporter-profile-visuals/manifest.json` and four TIFFs in that directory |
| Interactive UI acceptance | **NOT RUN** — available UI tests are launch/performance boilerplate and do not exercise the selector; launching the app against the host's Notes library was avoided | No synthetic-data UI launch harness is present |
| Real Apple Notes export | **NOT RUN** — requires a manually controlled local Notes library/acceptance pass | No real Notes data accessed |
| Direct MCP end-to-end exercise | **NOT RUN** — compatibility was assessed through source scope and app/CLI parity tests, not a live MCP session | MCP output is not claimed as runtime-validated |

The candidate app/unit test count is 37 higher than the baseline count (182 vs. 145); this is a count comparison, not a claim that every test has a one-to-one baseline counterpart. Candidate full-action status remains non-green because of the UI runner bootstrap error even though all 182 app/unit tests pass.

## 5. Component coverage and observable results

| Component | Input/fixture | Observable checks | Result |
|---|---|---|---|
| Parser A | Synthetic attribute runs: styled list item and plain/highlight/plain paragraph | Expected semantic HTML; balanced `li`/`mark`; extracted plaintext identical to original | **PASS** |
| Selection D | Synthetic account/folder/note state | Selection-state unit suite, including derived state | **PASS (unit only)**; interactive UI behavior **NOT RUN** |
| Configuration and renderer B | New and legacy JSON configuration; generated HTML with title, purple highlight, Monostyle code, 240×120 landscape image, a one-column table, explicit page break, and following-page text | Study default and backward decode; distinct profile output; at least two PDF pages; selectable text retains all markers | **PASS** |
| Standalone output C | Synthetic one-note fixture database | Flat `Note.pdf`; no staging directory delivered; collision suffixes do not overwrite; cancellation removes staging and does not deliver partial PDF | **PASS** |
| Multi-note PDF | Two synthetic selected notes with distinct IDs and marker text | Exactly two individual PDFs, expected names, one marker in each; no combined file | **PASS** |
| Attachments | Synthetic available image, unavailable image, file references, gallery reference and external URL | Available image rasterized; unavailable image reported as partial; no temporary staging links; unsupported originals/gallery explicitly marked incomplete; only intentional external URL remains clickable | **PASS for reporting behavior; portable originals remain unsupported** |
| Legacy and CLI compatibility | Existing synthetic legacy tree and CLI comparison fixtures | Legacy PDF tree preserved; app/CLI parity tests for supported text/package outputs pass | **PASS within tested fixtures** |
| Timeout/error/cancellation | Cancellation fixture; timeout implementation present in source | Cancellation cleanup tested; timeout-specific forced-timeout regression not present; UI runner failure is infrastructure/bootstrap rather than an exporter timeout | **PARTIAL** |

The synthetic profile-rendering HTML used by the test was:

```html
<h1>Profile rendering marker</h1>
<p>Inline <mark class="ane-highlight ane-highlight-purple">highlight</mark> survives.</p>
<pre class="ane-monostyle">let answer = 42</pre>
<figure><img alt="Synthetic landscape illustration" src="data:image/png;base64,[generated test image]"></figure>
<table><tr><th>Topic</th></tr><tr><td>Rendering</td></tr></table>
<div class="page-break"></div>
<h2>Following page marker</h2>
<p>Page-break content remains readable and selectable.</p>
```

The image is generated in test memory from colored geometric shapes; the placeholder above is descriptive, not a real payload. Faithful retained the left-aligned image placement of the input; Study centered the image. In both rendered samples the image remained proportional. The highlight, Monostyle background, table, headings, page break, and following-page selectable text were visible, with no observed clipping or overlap. These are synthetic visual checks, not proof against every Notes-generated HTML variant.

## 6. Baseline-to-candidate comparison

| Measure | Baseline `e05a858...` | Candidate integration worktree (based on `d618d78...` plus the P2 code/test patch) | Difference |
|---|---:|---:|---|
| App/unit tests passing | 145 | 182 | +37 passing cases |
| App/unit failures/skips | 0 / 0 | 0 / 0 | No unit regression observed |
| Full test action | Pass, 145 total | Integration worktree: 182 pass plus 1 UI-runner bootstrap failure | Candidate app/unit target passes separately; full action is not green |
| Flat single-note styled PDF route | No equivalent integrated route | Present in candidate patch and unit-tested | New path; not a like-for-like baseline behavior |
| Faithful/Study selectable and persisted | Not integrated | Present in candidate patch; synthetic render verified | New capability; no real UI persistence walkthrough |
| Multiple-note PDF behavior | Existing output behavior | One individual PDF per selected note, explicitly tested in candidate patch | No merged PDF claimed |
| CLI/MCP scope | Existing behavior | CLI kept outside app wiring; direct MCP session not run | Text/package parity tested; MCP runtime status remains unverified |

The same machine, Xcode installation, OS, test scheme, and deployment-target diagnostic setting were used. The baseline suite had 145 tests at that revision; new integration tests account for much of the candidate count increase, so raw counts are not a coverage-equivalence metric.

## 7. Issues, limitations, and next validation gate

1. **UI runner:** the full Xcode test action's UI runner terminated before bootstrapping. No claim is made that the search/profile/destination/export flow was clicked through. Existing UI test sources are boilerplate and do not test the new controls.
2. **Real Notes:** no manual export from a real Apple Note was performed. Acceptance against representative real Notes content remains required before release/distribution.
3. **Portable file attachments (P2-era status):** at that checkpoint generic files (including PDF, DOCX, Markdown, and binary attachments) and Notes galleries were not included as portable originals. P3 adds visible PDF-page insertion; non-PDF files/galleries remain incomplete, and the original PDF is not separately embedded as an attachment file.
4. **Timeout regression:** cancellation is covered, but a deterministic timeout-specific regression is not. Add one before claiming complete timeout/cancellation validation.
5. **MCP:** no live MCP invocation was run. Existing CLI/app parity tests do not substitute for a direct MCP contract/session test.
6. **Compiler note:** the candidate test build emitted a non-fatal warning for an unnecessary `await` around `setExportFolderTimestamps`; no compile error resulted.
7. **Selection/Finder actions:** code compiles and unit selection logic passes, but Finder reveal and end-to-end UX outcomes were not manually exercised.

No crash or unit-test regression was observed in the tested app/unit path. Given the UI bootstrap failure, absence of real Notes/UI acceptance, and incomplete portable attachment support, the appropriate status is **READY WITH LIMITATIONS**, not READY or release-complete.

## 8. Changed files and Git handoff

Application/test files changed by the P2 wiring and regression additions:

- `Apple Notes Exporter/Apple Notes Exporter/AppleNotesExporterView.swift`
- `Apple Notes Exporter/Apple Notes Exporter/Models/ExportConfiguration.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ViewModels/ExportViewModel.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/Apple_Notes_ExporterTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/EngineParityTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/ExportSupportTests.swift`

Integration documentation updated/added:

- `docs/notes-to-pdf/README.md`
- `docs/notes-to-pdf/ARCHITECTURE.md`
- `docs/notes-to-pdf/PARALLEL_PLAN.md`
- `docs/notes-to-pdf/INTEGRATION_REPORT.md`

Final handoff requirements: local commit on `codex/notes-pdf-integration`; clean integration worktree after commit; canonical `main` remains clean; no push or merge. The final HEAD SHA and final `git status` are supplied with the handoff because a report cannot contain the hash of its own containing commit without changing that hash.

## 9. Temporary-resource inventory

Task-related resources currently retained under `/private/tmp` for evidence/reproducibility:

- `/private/tmp/apple-notes-exporter-baseline-derived` — baseline Xcode result/build artifacts; needed to inspect the baseline 145/0/0 result.
- `/private/tmp/apple-notes-exporter-integration-derived` — earlier integration test bundles (including the pre-final 181-test run) and visual-test result data.
- `/private/tmp/apple-notes-exporter-integration-final-derived` — final candidate Xcode build/test artifacts and the two result bundles cited above.
- `/private/tmp/apple-notes-exporter-integration-packages` — resolved Swift package cache used by the candidate Xcode commands.
- `/private/tmp/apple-notes-exporter-profile-visuals` — four synthetic TIFF page captures and `manifest.json`, visually inspected for this report.

These contain synthetic test/build outputs only, not source-note data. They are retained temporarily so the user can inspect the evidence. They can be removed after review; the source branches/worktrees are not cleanup targets in this P2 handoff and were left intact.

## 10. P2.1 corrective checkpoint — 2026-10-24

**Checkpoint base:** `2b01d0f2c870939d2bcd86f2f3ba1fc23cb2c6e2` on `codex/notes-pdf-integration`.
**Worktree:** `/Users/gatti/.codex/worktrees/notes-pdf-integration/apple-notes-exporter`.
**Scope:** correction and regression coverage for findings F1–F5; no push, merge, rebase, reset, or source-worktree cleanup was performed.

### Initial dirty files and provenance

At the first authorized inspection of this checkpoint, these four files were already modified and unstaged in the integration worktree:

- `Apple Notes Exporter/Apple Notes Exporter/NoteHTMLGenerator.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/Apple_Notes_ExporterTests.swift`
- `Apple Notes Exporter/Apple Notes Exporter/HTMLAttachmentProcessor.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/ExportSupportTests.swift`

Because those edits were uncommitted on arrival, Git provides no author or source-branch provenance for them. They are attributed only to the pre-existing dirty state of this integration worktree; no attribution is made to the agent whose separate worktree-access attempt was rejected. That rejected attempt made no changes. The four source worktrees were not modified.

The corrective checkpoint also changes `ExportSupport.swift` and `ViewModels/ExportViewModel.swift` and updates this report. The complete resulting file list is in §11.

### Findings and corrections

- **F1 — PDF HTML/WebKit isolation: addressed.** Untrusted title/date metadata is HTML-escaped, the standalone document declares a restrictive CSP, and the renderer uses a fresh non-persistent WebKit data store with content JavaScript disabled. An HTTP(S) content rule blocks external loads, and the navigation delegate permits only the initial local/about main-frame document. Synthetic security tests verified the generated policy, escaped metadata, and configuration; no live malicious network endpoint test was run.
- **F2 — block formatting split across attributed runs: addressed.** The renderer now keeps a logical paragraph/block open across adjacent inline runs and closes it at structural boundaries. Regression coverage exercises heading, Monostile, and blockquote content split across styled runs, including emoji and newline boundaries.
- **F3 — orphan attachment markers in standalone PDF: addressed.** The actual `ExportViewModel` PDF path now processes HTML markers even when the note's attachment array is empty. When the Notes database or its attachment handle is unavailable, markers become escaped, explicit non-embedded references and incomplete-attachment diagnostics are recorded; unverified IDs are never used to fetch bytes. The active dictionary-building paths were checked: they use assignment loops rather than a trapping unique-key initializer; the unavailable-database fallback now selects the first duplicate ID deterministically, covered by regression.
- **F4 — cancellation while AppKit printing is pending: addressed for the pending-completion case.** A deterministic completion gate keeps the cancelled task suspended until the outstanding print completion callback arrives, after which cancellation is observed. The synthetic pending-callback regression passed. A separate timeout-specific regression remains an existing follow-up and is not claimed here.
- **F5 — diff hygiene: addressed.** Trailing whitespace was removed; `git diff --check` passes.

Additional verified issue: the initial test diff contained unescaped Swift string literals; the current test source parses and compiles, and its hostile-markup inputs are synthetic. No personal Notes data was used.

### P2.1 validation on 2026-10-24

The deployment target in project files was not changed. Xcode was invoked with the diagnostic build setting `MACOSX_DEPLOYMENT_TARGET=13.0` and code signing disabled for this local validation.

| Check | Outcome | Evidence |
|---|---|---|
| Complete app/CLI/MCP build action | **PASS** | `/private/tmp/apple-notes-p21-build.log` — `BUILD SUCCEEDED`; pre-existing warnings include unnecessary `await`, deprecated MCP API, and Combine visibility diagnostics. |
| Complete app/unit test target | **PASS** — 189 passed, 0 failed, 0 skipped | `/private/tmp/apple-notes-p21-full-test.log`; the test target ended with “All tests passed.” |
| P2.1 targeted regressions within that target | **PASS** — hostile HTML/metadata and link-scheme rejection; fragmented block formatting; orphan-marker view-model fallback; duplicate attachment IDs; PDF security configuration; pending-print cancellation | Same test log: `NoteHTMLGeneratorFormattingTests`, `HTMLAttachmentFallbackTests` (2), `PDFHTMLSecurityTests` (2), and `PDFPrintCancellationTests` (1). |
| Full scheme including UI tests | **PARTIAL / UI RUNNER ERROR** — all 189 app/unit tests passed, then `Apple Notes ExporterUITests-Runner` hung before establishing its test connection; `xcodebuild test` exited 65 | `/private/tmp/apple-notes-p21-full.xcresult` and the final failure lines in `/private/tmp/apple-notes-p21-full-test.log`. No UI test behavior is claimed. |
| Whitespace and conflict-marker check | **PASS** | `git diff --check`; final Git inventory to be reported with the checkpoint handoff. |

The UI-runner failure matches the environment limitation already recorded in §6–7. It does not negate the successful app/unit test target, but the full scheme is not green and UI acceptance remains open.

## 11. P2.1 changed files

- `Apple Notes Exporter/Apple Notes Exporter/ExportSupport.swift`
- `Apple Notes Exporter/Apple Notes Exporter/HTMLAttachmentProcessor.swift`
- `Apple Notes Exporter/Apple Notes Exporter/NoteHTMLGenerator.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ViewModels/ExportViewModel.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/Apple_Notes_ExporterTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/ExportSupportTests.swift`
- `docs/notes-to-pdf/INTEGRATION_REPORT.md`

## 12. P3 — multiple selection, attached PDFs, and UX checkpoint

**Decision: implementation checkpoint READY WITH LIMITATIONS; not release acceptance.**
**Date:** 2026-10-25
**Branch:** `codex/notes-pdf-integration`
**P3 base:** `f5f48ffa180c0f555400a51165db6a6abb06b0c2`

The implementation changes are local to the managed integration worktree. No push, merge, reset, cleanup, or source-worktree modification was performed. The automated fixtures and PDF previews use synthetic content only; no personal Notes were read into versioned fixtures.

### P3-A — multiple note selection

The selector now presents an explicit checkbox for each note, account/folder aggregate selection indicators, selected-note count, and clear/select actions. Selection is keyed by note IDs in the existing `NotesViewModel` selection state; highlighting a row remains navigation focus, not export selection. Filtering/browsing does not replace the selected-ID set. Existing output planning continues to produce one separate PDF per selected note, with the existing collision-safe naming path.

A synthetic UI test was added, but it did **not** complete: the UI-test runner stalled before establishing its test connection. Therefore the interactive checkbox, cross-folder retention, keyboard accessibility, resize behavior, and export-dialog flow are not claimed as UI-accepted on this run.

### P3-B — compact references with original PDF embedded (corrected requirement)

The app offers two persisted choices before export, both independent of Faithful/Study:

| Mode | Inline appearance at the original marker | Original PDF | Added note pages |
|---|---|---|---:|
| **Preview + embed** (default) | Small first-page thumbnail, PDF icon and filename | Embedded once per distinct attachment ID | 0 |
| **Embed only** | Compact PDF icon and filename; no thumbnail is generated | Embedded once per distinct attachment ID | 0 |

The source bytes are fetched through `fetchAttachment(id:ownedByNoteID:)`, so the repository verifies ownership against the note being exported. Marker replacement keeps each reference at its original position and sequence. Duplicate occurrences of one attachment ID are represented in place but create only one embedded file; conflicting bytes under a repeated ID fail closed. Different files with the same filename receive unique keys. The attachment remains extractable from the single exported PDF; no companion ZIP or sibling file is produced by this workflow.

`PDFEmbeddedFileWriter` writes document-level `/Names /EmbeddedFiles` file specifications using an incremental update, preserving existing trailer entries such as `/Info` and `/ID` while updating `/Size`, `/Root`, and `/Prev`. It does not add page objects to the note page tree. The generated PDF is reopened and its page count checked. A two-page note with an attached three-page synthetic PDF remained two pages; qpdf and Poppler extracted the embedded source byte-for-byte. Embedded-file support requires PDF 1.4; when needed the catalog version is raised through the incremental update. Encrypted, malformed, unsupported-xref, or already-attached source documents fail closed rather than being rewritten ambiguously.

Per-file and aggregate source-byte limits are 96 MiB and 256 MiB. Missing, locked, corrupt, oversized, or unplaceable inputs leave an explicit inline reference and warning or fail export when safe embedding cannot proceed. Available bytes from a damaged PDF are retained where possible, but the export is marked partial and no preview is generated. A valid PDF whose preview thumbnail fails still embeds unchanged and shows a preview-unavailable status.

The outer build occurs in a private 0700 staging directory. For final delivery, the completed PDF is copied into a destination-local private 0700 staging directory, restricted while staged, then moved to a collision-safe final name on the same volume; an existing file is never replaced. The final mode of the completed PDF is preserved. Temporary delivery staging is removed on success or failure.

**Practical reader check (2026-10-25, macOS 27.0.1):** Preview.app opened and rendered the synthetic note PDF, reporting “Page 1 of 2” and showing two note-page thumbnails; the embedded three-page source did not increase the note page count. The tested file was a writer-only fixture (it did not include the app-generated inline card). Preview's observed View sidebar offered Thumbnails, Table of Contents, Highlights and Notes, Bookmarks, and Contact Sheet; its Inspector offered General, Keywords, Encryption, Crop, and Annotations. No EmbeddedFiles list or open/extract command was exposed, so the original attachment could not be retrieved through the Preview UI in this test. Poppler 26.10.0 provides the independent reader-tool check: `pdfinfo` reported 2 pages and PDF 1.4, `pdftoppm` rendered the note page, `pdfdetach -list` found the embedded original, and `pdfdetach -save 1` recovered bytes identical to `three-page-source.pdf`. qpdf 12.4.2 `--check`, `--list-attachments`, and `--show-attachment` also passed. This establishes Preview note-page rendering plus Poppler attachment extraction, but **not** attachment extraction through Preview or compatibility with a second graphical viewer. Adobe Acrobat was not installed/launched and is not counted as a practical test. See [Adobe's attachment instructions](https://helpx.adobe.com/acrobat/desktop/edit-documents/use-links-and-attachments/open-attachment.html), [qpdf's attachment options](https://qpdf.readthedocs.io/en/stable/cli.html#embedded-files-attachments), and the [Preview User Guide](https://support.apple.com/guide/preview/welcome/mac).

### P3-C/P3-D — presentation and launch path

The selector is reorganized around an account/folder sidebar and central note list, with visible selection state; existing export options and engine remain in place. A synthetic in-memory UI-test host avoids reading the user's Notes store. The helper `scripts/run-integration-app.sh` builds the explicit integration `.xcodeproj`/scheme into isolated DerivedData and launches that exact product, using `MACOSX_DEPLOYMENT_TARGET=13.0` only as a command-line diagnostic override. Its syntax was checked with `bash -n`. The permanent project deployment target remains 11.0.

The stale UI seen when pressing ⌘R is **not diagnosed conclusively**. Explicit project/scheme settings point `SRCROOT`/`PROJECT_DIR` to this worktree, but the active Xcode window/run executable and any competing original-app process could not be verified. The script itself was not used as proof of interactive acceptance. No new manual Notes-library test was performed.

### Validation evidence and open failures

| Check | Outcome | Evidence |
|---|---|---|
| Focused corrected PDF-attachment regressions | **PASS — 9 passed, 0 failed, 0 skipped** | `/private/tmp/ANE-p3-correction-final-retest.log`; XCTest result `/private/tmp/ANE-p3-correction-derived/Logs/Test/Test-Apple Notes Exporter-2026.10.25_15-22-02-+0100.xcresult`; covers mode/marker order, cancellation, duplicate-ID conflict, filename collisions, qpdf round-trip and trailer preservation (`/Info`/`/ID`), Poppler extraction, no page expansion, both attachment modes crossed with both style profiles, and private same-volume delivery cleanup. |
| Complete app unit target | **PARTIAL — 196 passed, 1 failed** | `/private/tmp/ANE-p3-correction-unit-final.log`; XCTest result `/private/tmp/ANE-p3-correction-derived/Logs/Test/Test-Apple Notes Exporter-2026.10.25_12-40-59-+0000.xcresult`; `TZ=UTC`, `MACOSX_DEPLOYMENT_TARGET=13.0`, signing disabled for this diagnostic run. Sole failure: `test_zipDirectory_preservesFileModificationDates`, expected `1400000000`, observed `1400003600` (+3600 seconds). No ZIP implementation was changed for P3-B; the UTC retry did not resolve it, and its root cause remains unproven. |
| Independent reader-tool extraction | **PASS** | Poppler 26.10.0 `pdfdetach` listed and extracted the 3-page synthetic attachment byte-for-byte; Poppler `pdfinfo` reported 2 note pages. The test is skipped only where `pdfdetach` is absent. qpdf 12.4.2 checks and extraction also pass. |
| Preview.app practical check | **PARTIAL** | macOS 27.0.1 Preview opened and rendered the 2-page synthetic note PDF. Its observed sidebar and Inspector exposed no EmbeddedFiles list or open/extract action; Preview extraction is therefore not verified and was unavailable through the observed UI. Fixture was writer-only and did not test the app-generated visual card. |
| UI-test target | **NOT VERIFIED** | The earlier P3 attempt stalled before establishing a test connection; the target was not rerun during the Preview check. |
| Xcode ⌘R launch diagnosis | **OPEN** | The stale-UI cause was not established. This session could not inspect native Xcode/project windows because the Mac was locked; the explicit integration launcher remains available. |
| Faithful/Study visual inspection | **NOT PERFORMED AFTER THIS CORRECTION** | Automated tests cover text placement and page count in all mode/profile combinations, but no screenshot/visual review of the corrected compact cards was possible in the locked session. |
| Build and target settings | **PASS WITH DIAGNOSTIC OVERRIDES** | The app/unit target compiled during `xcodebuild test`; the permanent deployment target remains 11.0. `MACOSX_DEPLOYMENT_TARGET=13.0` and signing overrides were command-line-only. |
| Hygiene | **PASS** | `git diff --check`; script syntax is checked separately. No personal notes or attachments are test inputs. |

The default build without the command-line override is blocked by the installed Xcode/macOS SDK rejecting the unchanged deployment target 11.0 (the SDK reports a supported range starting at 12.0). No permanent target change was made. F2/P2.2-E—whether Apple Notes' serialized Monostile data reliably distinguishes internal newlines from consecutive block boundaries—remains open and is not resolved by these P3 changes.

### Files changed for the P3-B correction in the current worktree diff

- `Apple Notes Exporter/Apple Notes Exporter.xcodeproj/project.pbxproj`
- `Apple Notes Exporter/Apple Notes Exporter/AppleNotesExporterView.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ExportSupport.swift`
- `Apple Notes Exporter/Apple Notes Exporter/HTMLAttachmentProcessor.swift`
- `Apple Notes Exporter/Apple Notes Exporter/Models/ExportConfiguration.swift`
- `Apple Notes Exporter/Apple Notes Exporter/PDFEmbeddedFileWriter.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ViewModels/ExportViewModel.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/EngineParityTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/ExportSupportTests.swift`
- `docs/notes-to-pdf/ARCHITECTURE.md`
- `docs/notes-to-pdf/README.md`
- `docs/notes-to-pdf/INTEGRATION_REPORT.md`

### P3 changed files (earlier P3-A/P3-C work)

- `Apple Notes Exporter/Apple Notes Exporter/AppleNotesExporterApp.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ExportSupport.swift`
- `Apple Notes Exporter/Apple Notes Exporter/HTMLAttachmentProcessor.swift`
- `Apple Notes Exporter/Apple Notes Exporter/NoteSelectorView.swift`
- `Apple Notes Exporter/Apple Notes Exporter/Repository/NotesRepository.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ViewModels/ExportViewModel.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/ExportSupportTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterUITests/Apple_Notes_ExporterUITests.swift`
- `scripts/run-integration-app.sh`
- `docs/notes-to-pdf/ARCHITECTURE.md`
- `docs/notes-to-pdf/README.md`
- `docs/notes-to-pdf/INTEGRATION_REPORT.md`

No real-note data or personal notes were added to tests, fixtures, or documentation.

## 13. P3-D — final corrections after manual acceptance — 2026-10-25

**Worktree:** `/Users/gatti/.codex/worktrees/notes-pdf-integration/apple-notes-exporter`
**Branch / base:** `codex/notes-pdf-integration` / `9ff08914ea694cc83b99c6131f34c61f0197bd52`
**Checkpoint status:** local changes verified for the completed portions; **not ready for merge** while exact emoji text extraction and UI-runner verification remain open.

### Preflight and preserved working state

The current managed integration worktree was attached to this task. Its HEAD matched the requested base, and its initial dirty state exactly matched the preceding handoff; no unexpected source changes were found. The eight files already modified on arrival were:

- `Apple Notes Exporter/Apple Notes Exporter CLI/CLIExportEngine.swift`
- `Apple Notes Exporter/Apple Notes Exporter/AppleNotesExporterView.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ExportSupport.swift`
- `Apple Notes Exporter/Apple Notes Exporter/Models/ExportConfiguration.swift`
- `Apple Notes Exporter/Apple Notes Exporter/ViewModels/ExportViewModel.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/EngineParityTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterTests/ExportSupportTests.swift`
- `Apple Notes Exporter/Apple Notes ExporterUITests/Apple_Notes_ExporterUITests.swift`

These were uncommitted at inspection, so Git cannot attribute their authorship or earlier destination. They were preserved; no reset, rebase, push, merge, or worktree cleanup was performed. The canonical checkout and the four source worktrees were not modified. The permanent app deployment target remains 11.0; the macOS 13.0 value used for the successful build/test run was a command-line diagnostic override only.

### Findings

- **F1 — highlighted run boundaries: partially corrected; exact-text acceptance remains open.** The verified cause of the observed artificial spaces is horizontal padding on adjacent `<mark>` runs: the PDF fixture’s source contains `sviluppo`, while the prior padded positive control extracts as `svi luppo`. Both PDF style profiles now use zero horizontal highlight padding and square adjacent boundaries. The synthetic two- and three-run fixtures cover equal/different highlight colors, true spaces, bold/italic, accented text, emoji, and hard line breaks. Faithful and Study PDF images show continuous highlights; `pdftotext -raw` contains `sviluppo`, `frammentazione`, `colori`, `prima e dopo`, and the other tested words without artificial splits. The padding positive control reproduces the split.

  **Residual:** the rocket emoji renders visibly but is absent from both `PDFDocument.string`/copyable text and Poppler extraction. `pdffonts` reports MacRoman encoding with no Unicode map for the generated text fonts. Therefore exact text-copy fidelity for all Unicode/emoji is not established, and F1 must not be described as fully solved. No global whitespace normalization was introduced.

- **F2 — preview close control: implementation and regression coverage present; runtime UI verification blocked.** The title and large `Chiudi` control are in a dedicated top row, outside the PDF document view; the row is not part of the scrolling document area, and the close button has the macOS cancel/Escape shortcut. The UI test checks the control is hittable and above the PDF region and covers Escape. The test runner bundle failed with a system error (`Testing was canceled` / UI-test runner error) before test cases connected; it yielded 0 passed UI cases, so resizing and interactive close behavior are not claimed as verified in this run. The earlier user-reported P3-C manual 7/7 acceptance remains the accepted baseline and was not changed.

- **F3 — PDF attachment cards: no dead or staging link is emitted; the reported click failure was not reproduced as a page-card link.** In standalone-PDF mode the card is intentionally static: it contains the filename and has no `href`, `file://` URL, temporary path, or page URL annotation. The generated PDF stores attachments under the document-level `/EmbeddedFiles` name tree, rather than creating an external-file link from the visual card. On a synthetic two-page note PDF, Preview opened the document and displayed two pages; `pdfinfo -url` reported no URL links. `pdfdetach` listed and recovered the embedded `three-page-source.pdf`; SHA-256 of the recovered file exactly matched the source (`abf9f1f87b0c9290f1e8cfe594e83014d07fe57895565925b04f1e7a8751cb86`). The base note PDF and the same note with the embedded file both have 2 pages. The attachment’s embedded-file recovery is verified; opening/extracting it through Preview’s own attachment UI and reproducing the user's earlier permission message were not verified. No Acrobat Reader check was run, as requested. The static card must not be represented as clickable.

- **F4 — output organization: implemented and covered.** The persisted preference defaults to **Tutte insieme**, with legacy configurations lacking the key decoding to that default. The save-options UI uses **Tutte insieme** and **Come in Note**. App and CLI placement paths, duplicate-title allocation, attachment-sidecar collision avoidance, account/folder hierarchy placement, internal links, and ZIP/TAR export behavior have synthetic regression coverage. The UI test includes persistence across relaunch, but that UI assertion shares the runner block above and is not claimed as executed successfully.

### Validation actually completed

| Check | Result |
|---|---|
| App build with command-line `MACOSX_DEPLOYMENT_TARGET=13.0` override | **PASS** (separate build recorded in this checkpoint) |
| App/unit test scheme | **PASS — 206 passed, 0 failed, 0 skipped**; result bundle `/private/tmp/ANE-P3D-unit-suite.xcresult` |
| Focused highlighted-run Faithful/Study PDF regression | **PASS — 1 passed, 0 failed**; `/private/tmp/ANE-P3D-F1-final-focused.xcresult` |
| Offline format × destination matrix with synthetic fixture | **PASS — 68 passed, 0 failed** (18 formats; folder, ZIP, TAR, and single-file where supported) |
| ZIP smoke check using synthetic data outside the sandboxed file-coordination context | **PASS**; the earlier sandboxed run failed at macOS `NSFileCoordinator` ZIP creation, not at output validation |
| Embedded-file recovery / page-count / link inspection | **PASS** for the checks described under F3 |
| UI test runner | **BLOCKED — 0 UI test cases ran; runner system failure before connection** |
| `git diff --check` | **PASS** rerun after the report edit |
| Manual resize and direct attachment-open/extract interaction in Preview | **NOT VERIFIED** |

All automated inputs and exported PDFs used synthetic content. No personal Notes or attachments were used. The 68-cell matrix was rerun through the approved elevated path solely because sandboxed macOS file coordination had prevented ZIP creation; it completed with 68/68 passing.

### Remaining known risks and merge gate

1. Resolve or explicitly scope out the PDF renderer’s emoji/Unicode text-map loss, then assert exact extracted text across run boundaries without hiding artificial spaces through normalization.
2. Re-run UI tests when the runner can establish a connection; verify preview resize, fixed header, button close, and Escape.
3. Keep P2.2-E Monostile multiline boundaries, AppKit pending-print callback timeout, embedded-file support differences between readers, and stable Xcode ⌘R launch tracked separately. They are not resolved by P3-D.

**Changed files for P3-D:** the eight pre-existing modified files listed in the preflight above, plus this report. The code changes and report remain local to `codex/notes-pdf-integration`; there was no push or merge.
