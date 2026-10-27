# Parallel development plan — manual Codex delegation

Status: **P2 integration complete — READY WITH LIMITATIONS** on `codex/notes-pdf-integration`; see [INTEGRATION_REPORT.md](INTEGRATION_REPORT.md). The four implementation commits are preserved as ancestors of the integration branch. P3 items (portable generic-file/gallery attachments, merged multi-note PDF, and real Notes/UI acceptance) remain deferred or unverified. This file retains the original plan and prompts as historical execution guidance.

## Phase P0 — gate before workers (one agent)
1. Inspect actual local repo `~/Workspace/apple-notes-exporter` and relevant rules under sibling `development-environment` (`AGENTS.md`, engineering, version control, orchestration, tooling). Validate local repo path, branch, detached/uncommitted/unpushed state, remote origin and relevant worktrees. Do not destroy or overwrite unrecognized changes.
2. Verify baseline fork `SimoGatti04/apple-notes-exporter` and upstream `kzaremski/apple-notes-exporter`. Verify current HEAD against documented base, and do safe fast-forward reconciliation when clean. Set upstream remote if missing without replacing origin.
3. Run baseline `xcodebuild` listing/build/tests applicable on this Mac, record actual results and obstacles. Do not alter signing secrets or user's real Notes library.
4. Create/reuse exactly four *owned* independent persistent worktrees from the same verified base. Suggested branches: `codex/notes-parser`, `codex/pdf-layout`, `codex/export-output`, `codex/notes-ui`; describe worktree locations explicitly. No additional unowned worktrees. Stop before parallel coding if baseline is dirty/unreconciled or shared contract is ambiguous.
5. Return a compact handoff listing base SHA, upstream/origin, worktree-to-agent map, test outcome and any blocked issue. Preserve README/LICENSE and licensing notices.

## Phase P1 — independent parallel worker threads (A, B, C, D)
All use the frozen [architecture contracts](ARCHITECTURE.md) and a single P0 base. Agents never work on canonical `main` and never modify the same file. One worktree per agent; each agent commits only its own changes and documents real test results.

| Agent | Goal | Exclusive file set | Gate to accept |
|---|---|---|---|
| A — parser | Preserve Monostyle, highlights, text color/emphasis and avoid incorrect attr-run merges | `NoteHTMLGenerator.swift` + assigned test source | synthetic protobuf/HTML fixture proves formatting preserved and plaintext unchanged |
| B — PDF | Two CSS/HTML layouts + proportional centered images and sane page breaks | `ExportSupport.swift` + assigned tests | isolated rendering helper tested; no regression to existing plain HTML |
| C — delivery | Single note → flat PDF, stable filename/collision behavior, clean temp lifecycle, explicit attachment warnings | `ExportViewModel.swift`, `HTMLAttachmentProcessor.swift`, assigned tests | no unwanted tree; standalone images visible; no silent missing-file claims |
| D — UI | Search, single/multi note selection, folder partial-selection correctness, intuitive selection experience | UI + selection-model files, assigned UI tests | mock/manual navigation and selection scenario verified |

**Critical:** A → B styles are a documented HTML class contract, not a source-level dependency during parallel coding. C → D integration should occur only after both agent branches are tested. B/C must not simultaneously edit the same existing file.

## Phase P2 — integrator (serial work)
A dedicated integrator (user manually starts separate agent after P1 reviews) inspects actual commits/diffs, not reports alone. Integrate in order A → B → C → D when feasible. Integrator exclusively owns shared config, project file, cross-module API changes, default choice of layout, attachment package selection, and GUI-to-backend wiring. If contract conflicts are material, stop and have affected agent revise its own branch.

Run project build/tests and actual end-to-end export of *synthetic* notes; then user can locally test private notes without sharing them. Update docs with precise PASS/FAIL, unsupported formats and next milestones. Final deployment/release is NOT implied by merge.

## Phase P3 — separately scoped improvement
Once the vertical slice is validated: implement verified PDF embedded file attachments or reliable ZIP package, PDF/Office/Markdown previews and internal link resolution, multi-note PDF combining, richer GUI preview and profile persistence. Do not make Phase P1 expand into speculative OCR, crawlers or massive format conversions.

## Conflict/cleanup rules
- Repo source of truth = published fork branch/verified local commit, not conversational reports.
- Keep `main` canonical and clean; one agent = one named branch + worktree. No force pushes/resets, no worktree removal unless ownership and unique-work preservation are verified.
- On worker completion: report touched paths, commit SHA, diff scope, test commands with result, known failures/unsupported behavior, temporary resources and cleanup status. Push branch only after checking correct remote (user fork).
- Do not automatically merge worker branches into `main`. User forwards reports; supervisor reviews; integrator merges after P2 gates.
- Read the sibling dev-env norms before modifications; user decisions override their defaults where stated. No personal notes in repo or CI.
