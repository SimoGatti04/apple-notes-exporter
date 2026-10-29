# Notes to PDF — post-beta roadmap

This is a planning document, not a promise that any item below is already implemented. The current released baseline is `v0.1.0-beta.1`; do not change its tag, source commit, or published artifacts.

## Shipped in v0.1.0-beta.1

- Multi-selection with a separate PDF per note, Faithful/Study layouts, live preview, and All together/Like in Notes output organization.
- Compact attachment presentation with either a preview or filename-only reference, plus embedding of the original PDF where available and authorized. Attachment pages are not appended to the note PDF.
- Ownership checks, bounded attachment handling, private staging, atomic delivery, and failure/partial-result reporting.

## Known issues and limits (not roadmap promises)

- Some emoji are visible in the rendered PDF but may be absent or reordered in copied/extracted text.
- Some multiline Monostile formatting may fragment, and original block boundaries are not always reconstructed.
- Readers differ in whether they expose embedded PDF files for opening or extraction; Preview on the tested system showed no extraction action.
- Cancellation may not stop an AppKit print operation that is already blocked.
- Only macOS 27.0.1 on Apple Silicon was verified. The macOS 11.0 Xcode deployment target is not a compatibility claim.
- Release UI verification remains incomplete for All together export to a selected folder and end-to-end PDF attachment extraction. Both were accepted as Beta risks and remain NOT RUN.

## Suggested next steps

1. **Release validation:** run a short, repeatable synthetic UI checklist for multi-note All together output and PDF attachment embedding/extraction on the actual Release app, then record the reader, OS, and results. Do not use personal notes as fixtures.
2. **Text fidelity:** investigate Unicode mapping and copied-text ordering with controlled PDFs and multiple extractors; improve only where results are reproducible, and keep visual fidelity and accessibility trade-offs documented.
3. **Monostile fidelity:** gather additional structural evidence before changing parsing; prefer conservative layout where source block boundaries cannot be known reliably.
4. **Attachment interoperability:** test extraction in more than one compatible PDF reader and document supported workflows without assuming every viewer offers the same UI.
5. **Distribution readiness:** evaluate Developer ID signing and notarization before a stable release; broaden the macOS compatibility matrix only after direct testing on each claimed release.

Optional UI polish, more export controls, and additional reader or OS coverage should follow user feedback and regression evidence. Preserve the upstream exporter separately from Notes-to-PDF changes when describing features.
