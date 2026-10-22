//
//  Apple_Notes_ExporterTests.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//
//  Suite-level setup placeholder. Actual test cases live in topic-specific
//  files (ExportSupportTests.swift, etc.).
//

import XCTest
@testable import Apple_Notes_Exporter

final class Apple_Notes_ExporterTests: XCTestCase {
    // Intentionally empty. Add tests in topic-specific files within this target.
}

final class NotesHierarchyRobustnessTests: XCTestCase {

    private func account(_ id: String, name: String = "iCloud") -> NotesAccount {
        NotesAccount(id: id, name: name, identifier: "id-\(id)", accountType: .iCloud)
    }

    private func folder(_ id: String, name: String, parent: String?, account: String) -> NotesFolder {
        NotesFolder(id: id, name: name, parentId: parent, accountId: account)
    }

    private func note(_ id: String, folder: String, account: String) -> NotesNote {
        NotesNote(
            id: id,
            title: "Note \(id)",
            plaintext: "body",
            htmlBody: nil,
            creationDate: Date(),
            modificationDate: Date(),
            folderId: folder,
            accountId: account,
            attachments: []
        )
    }

    func test_orphanFolderWithDanglingParent_becomesRoot() {
        let acct = account("1")
        let folders = [
            folder("10", name: "Work", parent: "999", account: "1")
        ]
        let notes = [note("100", folder: "10", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: folders, notes: notes)
        XCTAssertEqual(tree.accounts.count, 1)
        XCTAssertEqual(tree.accounts[0].folders.count, 1)
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, "Work")
        XCTAssertEqual(tree.accounts[0].folders[0].totalNoteCount, 1)
    }

    func test_folderWithUnknownAccount_inferredFromNotes() {
        let acct = account("1")
        let folders = [
            folder("10", name: "Inbox", parent: nil, account: "")
        ]
        let notes = [note("100", folder: "10", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: folders, notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.first?.totalNoteCount, 1)
    }

    // The tree has to agree with what the exporter writes to disk. Loose notes
    // go to the account's default folder in both, not to a separate "Unfiled"
    // node that exists only in the UI.

    func test_notesWithoutFolder_landInDefaultFolderWhenThereAreNoFolders() {
        let acct = account("1")
        let notes = [note("100", folder: "missing", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: [], notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.count, 1)
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, fallbackNotesFolderName)
        XCTAssertEqual(tree.accounts[0].folders[0].notes.count, 1)
    }

    func test_notesWithoutFolder_mergeIntoExistingDefaultFolderNode() {
        let acct = account("1")
        let defaultFolder = NotesFolder(
            id: "10", name: "Notes", parentId: nil, accountId: "1",
            identifier: "DefaultFolder-CloudKit"
        )
        let notes = [
            note("100", folder: "10", account: "1"),
            note("101", folder: "missing", account: "1")
        ]

        let tree = NotesHierarchy.build(accounts: [acct], folders: [defaultFolder], notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.count, 1, "should not add a sibling node")
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, "Notes")
        XCTAssertEqual(tree.accounts[0].folders[0].totalNoteCount, 2)
    }

    func test_notesWithoutFolder_useLocalizedDefaultFolderName() {
        let acct = account("1")
        let localized = NotesFolder(
            id: "10", name: "Notizen", parentId: nil, accountId: "1",
            identifier: "DefaultFolder-CloudKit"
        )
        let notes = [note("100", folder: "missing", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: [localized], notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.count, 1)
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, "Notizen")
        XCTAssertEqual(tree.accounts[0].folders[0].totalNoteCount, 1)
    }
}


final class NotesSelectionStateTests: XCTestCase {
    private func account() -> NotesAccount {
        NotesAccount(id: "account", name: "iCloud", identifier: "synthetic", accountType: .iCloud)
    }

    private func folder(_ id: String, name: String, parent: String? = nil) -> NotesFolder {
        NotesFolder(id: id, name: name, parentId: parent, accountId: "account")
    }

    private func note(_ id: String, title: String, folderId: String, accountId: String = "account") -> NotesNote {
        NotesNote(
            id: id,
            title: title,
            plaintext: "Synthetic body",
            htmlBody: nil,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            folderId: folderId,
            accountId: accountId,
            attachments: []
        )
    }

    func testFolderSelectionStateIsDerivedAfterIndividualNoteChanges() {
        let parent = folder("parent", name: "Projects")
        let child = folder("child", name: "Research", parent: "parent")
        let notes = [
            note("parent-note", title: "Plan", folderId: "parent"),
            note("child-note", title: "Findings", folderId: "child")
        ]
        let hierarchy = NotesHierarchy.build(accounts: [account()], folders: [parent, child], notes: notes)
        let folderNode = try! XCTUnwrap(hierarchy.accounts.first?.folders.first)
        var selection = NotesSelectionState()

        XCTAssertEqual(selection.selectionStatus(for: ["parent-note", "child-note"]), .none)
        selection.toggleNote("parent-note")
        XCTAssertEqual(selection.selectionStatus(for: ["parent-note", "child-note"]), .partial)
        XCTAssertFalse(selection.isFolderSelected("parent", in: hierarchy))

        selection.selectFolder(folderNode)
        XCTAssertEqual(selection.selectionStatus(for: ["parent-note", "child-note"]), .all)
        XCTAssertTrue(selection.isFolderSelected("parent", in: hierarchy))

        selection.toggleNote("child-note")
        XCTAssertEqual(selection.selectionStatus(for: ["parent-note", "child-note"]), .partial)
        XCTAssertFalse(selection.isFolderSelected("parent", in: hierarchy))

        selection.deselectFolder(folderNode)
        XCTAssertEqual(selection.selectionStatus(for: ["parent-note", "child-note"]), .none)
    }

    @MainActor
    func testDuplicateTitlesRemainDistinctAndSearchReturnsBothIDs() {
        let notes = [
            note("work-copy", title: "Meeting", folderId: "work"),
            note("personal-copy", title: "Meeting", folderId: "personal")
        ]
        var selection = NotesSelectionState()
        selection.toggleNote("work-copy")

        XCTAssertEqual(NotesViewModel.filterNotes(notes, matchingTitle: "meeting").map(\.id), ["work-copy", "personal-copy"])
        XCTAssertEqual(selection.selectedNotes(from: notes).map(\.id), ["work-copy"])
        XCTAssertNotEqual(notes[0].id, notes[1].id)
    }

    @MainActor
    func testAccountAndNestedFolderScopesUseSyntheticHierarchy() async {
        let repository = MockNotesRepository()
        let work = NotesAccount(id: "work-account", name: "Work iCloud", identifier: "work", accountType: .iCloud)
        let personal = NotesAccount(id: "personal-account", name: "Personal", identifier: "personal", accountType: .local)
        repository.mockAccounts = [work, personal]
        repository.mockFolders = [
            NotesFolder(id: "projects", name: "Projects", parentId: nil, accountId: work.id),
            NotesFolder(id: "research", name: "Research", parentId: "projects", accountId: work.id),
            NotesFolder(id: "inbox", name: "Inbox", parentId: nil, accountId: personal.id)
        ]
        repository.mockNotes = [
            note("work-note", title: "Roadmap", folderId: "projects", accountId: work.id),
            note("research-note", title: "Annual review", folderId: "research", accountId: work.id),
            NotesNote(
                id: "personal-note", title: "Annual review", plaintext: "Synthetic body", htmlBody: nil,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                modificationDate: Date(timeIntervalSince1970: 1_700_000_100), folderId: "inbox",
                accountId: personal.id, attachments: []
            )
        ]
        let viewModel = NotesViewModel(repository: repository)

        await viewModel.loadNotes()

        XCTAssertEqual(Set(viewModel.notes(in: .account(work.id)).map(\.id)), ["work-note", "research-note"])
        XCTAssertEqual(Set(viewModel.notes(in: .folder("projects")).map(\.id)), ["work-note", "research-note"])
        XCTAssertEqual(viewModel.scopeTitle(for: .folder("projects")), "Projects")
        XCTAssertEqual(viewModel.locationDescription(for: repository.mockNotes[1]), "Work iCloud · Research")
        XCTAssertEqual(NotesViewModel.filterNotes(viewModel.allNotes, matchingTitle: "annual").count, 2)
        XCTAssertEqual(viewModel.selectedCount, 0, "loading a library must not preselect all notes")
    }

    func testChangingVisibleListSelectionPreservesHiddenSelections() {
        var selection = NotesSelectionState()
        selection.setNotes(["first", "hidden"], selected: true)

        selection.updateVisibleSelection(["third"], visibleIDs: ["first", "third"])

        XCTAssertEqual(selection.selectedNoteIDs, ["hidden", "third"])
    }

    func testEmptyFolderHasNoSelectionState() {
        let empty = NotesHierarchy.build(
            accounts: [account()],
            folders: [folder("empty", name: "Empty")],
            notes: []
        ).accounts[0].folders[0]
        let selection = NotesSelectionState()

        XCTAssertEqual(selection.selectionStatus(for: []), .none)
        var duplicateIDSelection = NotesSelectionState()
        duplicateIDSelection.toggleNote("same-id")
        XCTAssertEqual(duplicateIDSelection.selectionStatus(for: ["same-id", "same-id"]), .all)
        XCTAssertFalse(selection.isFolderSelected(empty.folder.id, in: NotesHierarchy(accounts: [
            NotesHierarchy.AccountNode(account: account(), folders: [empty])
        ])))
    }
}
