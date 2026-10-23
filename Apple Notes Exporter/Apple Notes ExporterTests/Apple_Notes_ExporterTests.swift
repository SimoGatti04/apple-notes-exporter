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

final class NoteHTMLGeneratorFormattingTests: XCTestCase {
    private func note(_ text: String, runs: [AttributeRun]) -> Note {
        var note = Note()
        note.noteText = text
        note.attributeRun = runs
        return note
    }

    private func run(_ text: String) -> AttributeRun {
        var run = AttributeRun()
        run.length = Int32(text.utf16.count)
        return run
    }

    private func plaintext(from html: String) -> String {
        let withLineBreaks = html.replacingOccurrences(of: "<br>", with: "\n")
        let withoutTags = withLineBreaks.replacingOccurrences(
            of: "<[^>]*>", with: "", options: .regularExpression
        )
        // Decode ampersands last so source text such as the literal "&lt;"
        // (escaped by the generator to "&amp;lt;") is decoded only once.
        return withoutTags
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    func test_adjacentRunsWithDifferentColorAndHighlightRemainDistinct() {
        let text = "RedPink"
        var red = run("Red")
        red.color = Color()
        red.color.red = 1
        red.color.green = 0
        red.color.blue = 0
        red.color.alpha = 1
        red.emphasisStyle = 1

        var pink = run("Pink")
        pink.color = Color()
        pink.color.red = 0
        pink.color.green = 0
        pink.color.blue = 1
        pink.color.alpha = 0.5
        pink.emphasisStyle = 2

        let html = NoteHTMLGenerator(database: nil).generateHTML(from: note(text, runs: [red, pink]))

        XCTAssertTrue(html.contains("color: rgb(255, 0, 0)"))
        XCTAssertTrue(html.contains("color: rgba(0, 0, 255, 0.500)"))
        XCTAssertTrue(html.contains("class=\"ane-highlight ane-highlight-purple\">Red</mark>"))
        XCTAssertTrue(html.contains("class=\"ane-highlight ane-highlight-pink\">Pink</mark>"))
        XCTAssertEqual(plaintext(from: html), text)
    }

    func test_adjacentStyledRunsKeepTheirOwnTextRangesIncludingEmoji() {
        let text = "A🚀B"
        var first = run("A")
        first.fontWeight = 1
        var emoji = run("🚀")
        emoji.fontWeight = 2
        let last = run("B")

        let html = NoteHTMLGenerator(database: nil).generateHTML(
            from: note(text, runs: [first, emoji, last])
        )

        XCTAssertTrue(html.contains("<b>A</b><i>🚀</i>B"))
        XCTAssertEqual(plaintext(from: html), text)
    }

    func test_unrecognizedEmphasisIsPreservedWithoutInventingAHighlightColor() {
        let text = "Future style"
        var run = run(text)
        run.emphasisStyle = 77

        let html = NoteHTMLGenerator(database: nil).generateHTML(from: note(text, runs: [run]))

        XCTAssertTrue(html.contains("data-ane-emphasis-style=\"77\""))
        XCTAssertFalse(html.contains("class=\"ane-highlight"))
        XCTAssertEqual(plaintext(from: html), text)
    }

    func test_monostyleHasSemanticClassAndFallbackStyling() {
        let text = "let value = 42"
        var run = run(text)
        run.paragraphStyle = ParagraphStyle()
        run.paragraphStyle.styleType = 4

        let html = NoteHTMLGenerator(database: nil).generateHTML(from: note(text, runs: [run]))

        XCTAssertTrue(html.contains("<pre class=\"ane-monostyle\""))
        XCTAssertTrue(html.contains("font-family: monospace"))
        XCTAssertEqual(plaintext(from: html), text)
    }

    func test_inlineFormattingAndTypographyAreEmittedWithoutChangingText() {
        let text = "Marked & <safe>"
        var run = run(text)
        run.fontWeight = 3
        run.underlined = 1
        run.strikethrough = 1
        run.font = Font()
        run.font.fontName = "Menlo"
        run.font.pointSize = 13.5
        run.paragraphStyle = ParagraphStyle()
        run.paragraphStyle.styleType = 1
        run.paragraphStyle.alignment = 1
        run.link = "https://example.com/a?x=1&y=2"

        let html = NoteHTMLGenerator(database: nil).generateHTML(from: note(text, runs: [run]))

        XCTAssertTrue(html.contains("<h2 style=\"text-align: center;\">"))
        XCTAssertTrue(html.contains("font-family: &quot;Menlo&quot;"))
        XCTAssertTrue(html.contains("font-size: 13.5pt"))
        XCTAssertTrue(html.contains("<b><i><u><s><a href=\"https://example.com/a?x=1&amp;y=2\">"))
        XCTAssertEqual(plaintext(from: html), text)
    }

    func test_superscriptAndSubscriptRemainSemanticallyDistinct() {
        let text = "x2y3"
        var base = run("x")
        base.length = 1
        var superscript = run("2")
        superscript.superscript = 1
        var middle = run("y")
        middle.length = 1
        var subscriptRun = run("3")
        subscriptRun.superscript = -1

        let html = NoteHTMLGenerator(database: nil).generateHTML(
            from: note(text, runs: [base, superscript, middle, subscriptRun])
        )

        XCTAssertTrue(html.contains("<sup>2</sup>"))
        XCTAssertTrue(html.contains("<sub>3</sub>"))
        XCTAssertEqual(plaintext(from: html), text)
    }

    func test_listFormattingIsRetained() {
        let text = "First"
        var run = run(text)
        run.fontWeight = 1
        run.paragraphStyle = ParagraphStyle()
        run.paragraphStyle.styleType = 100

        let html = NoteHTMLGenerator(database: nil).generateHTML(from: note(text, runs: [run]))

        XCTAssertTrue(html.contains("<ul><li><b>First</b></li></ul>"))
        XCTAssertEqual(plaintext(from: html), text)
    }
}
