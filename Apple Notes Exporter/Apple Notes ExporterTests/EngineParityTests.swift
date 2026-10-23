//
//  EngineParityTests.swift
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

import XCTest
import AppKit
import PDFKit
import SQLite3
@testable import Apple_Notes_Exporter

/// Exports the same notes through the app's engine and the CLI's engine and
/// compares what lands on disk.
///
/// Every bug in this codebase's largest class had the same shape: two engines
/// implementing one behaviour, drifting apart, and nothing noticing. Those were
/// found by reading the two implementations side by side, which does not scale
/// and does not stay done. This does.
///
/// It runs against a generated legacy-schema database, so it needs no Notes
/// library and no Full Disk Access.
@MainActor
final class EngineParityTests: XCTestCase {

    // MARK: - Fixture

    /// The legacy (iOS 8) schema: four plain tables with raw-text bodies. The
    /// parser selects it when ZICNOTEDATA is absent, which avoids needing a
    /// protobuf generator just to have something to export.
    private static let fixtureSQL = """
    CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZACCOUNTIDENTIFIER TEXT, ZNAME TEXT);
    CREATE TABLE ZSTORE (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZACCOUNT INTEGER);
    CREATE TABLE ZNOTEBODY (Z_PK INTEGER PRIMARY KEY, ZCONTENT TEXT);
    CREATE TABLE ZNOTE (Z_PK INTEGER PRIMARY KEY, ZCREATIONDATE REAL,
                        ZMODIFICATIONDATE REAL, ZTITLE TEXT, ZBODY INTEGER, ZSTORE INTEGER);
    INSERT INTO ZACCOUNT VALUES (1, 'fixture-account-1', 'Fixture');
    INSERT INTO ZSTORE VALUES (1, 'Notes', 1);
    INSERT INTO ZSTORE VALUES (2, 'Work', 1);
    INSERT INTO ZNOTEBODY VALUES (1, 'Body with an ampersand & a <tag> and "quotes".');
    INSERT INTO ZNOTEBODY VALUES (2, 'Second note. Unicode: café — dash.');
    INSERT INTO ZNOTEBODY VALUES (3, 'Third note in the Work folder.');
    INSERT INTO ZNOTE VALUES (1, 727012800, 728559000, 'First Note', 1, 1);
    INSERT INTO ZNOTE VALUES (2, 727012800, 728559000, 'Second Note & Friends', 2, 1);
    INSERT INTO ZNOTE VALUES (3, 727012800, 728559000, 'Work Note', 3, 2);
    """

    private func makeFixtureDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let db = dir.appendingPathComponent("NoteStore.sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(Self.fixtureSQL.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: db.path) else {
            throw XCTSkip("could not build the fixture database with /usr/bin/sqlite3")
        }
        return db.path
    }

    private func makeOutputDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeNote(
        title: String = "Flat Note",
        htmlBody: String = "<html><body><p>Standalone PDF body</p></body></html>",
        attachments: [NotesAttachment] = []
    ) -> NotesNote {
        NotesNote(
            id: "synthetic-note", title: title, plaintext: "Standalone PDF body", htmlBody: htmlBody,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            folderId: "1", accountId: "1", attachments: attachments
        )
    }

    private func executeSQL(_ sql: String, databasePath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databasePath, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "EngineParityTests.SQLite", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "EngineParityTests.SQLite", code: 2)
        }
    }

    private func openAttachmentTestDatabase() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            throw NSError(domain: "EngineParityTests.SQLite", code: 3)
        }
        let schema = """
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            ZIDENTIFIER TEXT PRIMARY KEY, ZMEDIA BLOB, ZURLSTRING TEXT, ZTITLE TEXT,
            ZALTTEXT TEXT, ZMARKEDFORDELETION INTEGER
        );
        INSERT INTO ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER, ZURLSTRING, ZTITLE, ZMARKEDFORDELETION)
            VALUES ('web-link', 'https://example.test/guide', 'External guide', 0);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "EngineParityTests.SQLite", code: 4)
        }
        return db
    }

    private func flatPDFStagingPaths() -> Set<String> {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let children = (try? FileManager.default.contentsOfDirectory(
            at: temporaryRoot, includingPropertiesForKeys: nil
        )) ?? []
        return Set(children.filter { $0.lastPathComponent.hasPrefix("apple-notes-exporter-pdf-") }.map(\.path))
    }

    private func makeSolidPNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "EngineParityTests.Image", code: 1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 48, height: 48)).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "EngineParityTests.Image", code: 2)
        }
        return png
    }

    // MARK: - Comparison

    /// Dates are stamped at export time and legitimately differ between two
    /// runs, so they are masked before comparing. Everything else must match.
    private func normalize(_ text: String) -> String {
        var result = text
        let datePatterns = [
            #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"#,      // ISO 8601
            #"\d{8}T\d{6}Z"#,                                       // ENEX
            #"\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}"#, // RFC 822
            #"\w{3} \d{1,2}, \d{4} at \d{1,2}:\d{2}\s?[AP]M"#,      // medium/short
            #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
        ]
        for pattern in datePatterns {
            result = result.replacingOccurrences(
                of: pattern, with: "<DATE>", options: .regularExpression)
        }
        return result
    }

    private func filesUnder(_ root: URL) -> [String: String] {
        var files: [String: String] = [:]
        // /var and /private/var are the same place; resolve so the relative
        // path strips cleanly whichever form the enumerator hands back.
        let base = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue, !url.lastPathComponent.hasPrefix(".") else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            let relative = resolved.hasPrefix(base + "/")
                ? String(resolved.dropFirst(base.count + 1))
                : url.lastPathComponent
            files[relative] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
        }
        return files
    }

    // MARK: - Driving each engine

    private func exportViaApp(
        format: ExportFormat, db: String, to output: URL, configure: (inout ExportConfigurations) -> Void = { _ in }
    ) async throws {
        let repository = DatabaseNotesRepository(databasePath: db)
        let viewModel = ExportViewModel(repository: repository, databasePath: db)
        // Not ExportConfigurations.load(): that reads this machine's real
        // preferences and would make the comparison depend on them.
        var configs = ExportConfigurations.default
        configure(&configs)
        viewModel.configurations = configs

        let notes = try await repository.fetchNotes(includeDeleted: false)
        await viewModel.exportNotes(notes, toDirectory: output, format: format, includeAttachments: true)
    }

    private func exportViaCLI(
        format: ExportFormat, db: String, to output: URL, configure: (inout ExportConfigurations) -> Void = { _ in }
    ) async throws {
        var configs = ExportConfigurations.default
        configure(&configs)
        let engine = CLIExportEngine(databasePath: db, configurations: configs)
        let repository = DatabaseNotesRepository(databasePath: db)
        let notes = try await repository.fetchNotes(includeDeleted: false)
        _ = try await engine.exportNotes(
            notes, toDirectory: output, format: format,
            includeAttachments: true, verbose: false,
            allKnownNoteIds: Set(notes.map(\.id)),
            progressHandler: { _, _ in }
        )
    }

    // MARK: - Tests

    func test_singleNotePDFWritesFlatAndRemovesStagingDirectory() async throws {
        let db = try makeFixtureDatabase()
        let output = try makeOutputDirectory()
        let stagingBefore = flatPDFStagingPaths()
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: db), databasePath: db
        )

        await viewModel.exportSingleNotePDF(makeNote(), toDirectory: output)

        guard case .completed(let statistics) = viewModel.exportState else {
            return XCTFail("Expected completed export, got \(viewModel.exportState)")
        }
        XCTAssertEqual(statistics.successfulNotes, 1)
        XCTAssertEqual(statistics.failedAttachments, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["Flat Note.pdf"])
        XCTAssertEqual(viewModel.lastExportArtifactURL?.lastPathComponent, "Flat Note.pdf")
        XCTAssertEqual(flatPDFStagingPaths(), stagingBefore)
        XCTAssertNotNil(PDFDocument(url: output.appendingPathComponent("Flat Note.pdf")))
    }

    func test_standalonePDFPaginatesAtConfiguredSizeAndKeepsTextSelectable() async throws {
        let db = try makeFixtureDatabase()
        let output = try makeOutputDirectory()
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: db), databasePath: db
        )
        var configurations = ExportConfigurations.default
        configurations.pdf.pageSize = .a5
        configurations.pdf.htmlConfiguration.marginSize = 24
        configurations.pdf.htmlConfiguration.marginUnit = .pt
        viewModel.configurations = configurations

        let body = (1...100).map { index in
            "<p>Selectable pagination paragraph \(index) with enough words to occupy printable width.</p>"
        }.joined()
        let finalMarker = "Selectable page marker 100"
        let note = makeNote(
            htmlBody: "<html><body>\(body)<p>\(finalMarker)</p></body></html>"
        )

        await viewModel.exportSingleNotePDF(note, toDirectory: output)

        guard case .completed = viewModel.exportState,
              let pdf = PDFDocument(url: output.appendingPathComponent("Flat Note.pdf")),
              let firstPage = pdf.page(at: 0) else {
            return XCTFail("Expected a valid multi-page standalone PDF")
        }
        XCTAssertGreaterThan(pdf.pageCount, 1, "The whole document should paginate, not clip at the viewport")
        let pageBounds = firstPage.bounds(for: .mediaBox)
        XCTAssertEqual(pageBounds.width, 420, accuracy: 2)
        XCTAssertEqual(pageBounds.height, 595, accuracy: 2)
        let firstParagraphSelection = try XCTUnwrap(
            pdf.findString("Selectable pagination paragraph 1", withOptions: []).first
        )
        let firstParagraphBounds = firstParagraphSelection.bounds(for: firstPage)
        XCTAssertGreaterThanOrEqual(firstParagraphBounds.minX, 20, "Configured left margin should be honored")
        XCTAssertGreaterThan(pageBounds.maxY - firstParagraphBounds.maxY, 20,
                             "Configured top margin should be honored")
        let selectableText = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: " ")
        XCTAssertTrue(selectableText.contains("Selectable pagination paragraph 1"))
        XCTAssertTrue(selectableText.contains(finalMarker))
    }

    func test_standalonePDFCollisionMovePreservesExistingFile() throws {
        let output = try makeOutputDirectory()
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent("ane-pdf-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: staging) }

        let existingPDF = output.appendingPathComponent("Flat Note.pdf")
        let sentinel = Data("existing user file".utf8)
        try sentinel.write(to: existingPDF)
        let stagedPDF = staging.appendingPathComponent("rendered.pdf")
        let generatedBytes = Data("generated PDF bytes".utf8)
        try generatedBytes.write(to: stagedPDF)

        let deliveredURL = try ExportViewModel.moveFlatPDFWithoutOverwriting(
            stagedPDF,
            noteTitle: "Flat Note",
            toDirectory: output
        )

        XCTAssertEqual(deliveredURL.lastPathComponent, "Flat Note (2).pdf")
        XCTAssertEqual(try Data(contentsOf: existingPDF), sentinel)
        XCTAssertEqual(try Data(contentsOf: deliveredURL), generatedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPDF.path))
    }

    func test_singleNotePDFNeverOverwritesAndUsesStableCollisionSuffixes() async throws {
        let db = try makeFixtureDatabase()
        let output = try makeOutputDirectory()
        let original = output.appendingPathComponent("Flat Note.pdf")
        let sentinel = Data("pre-existing user data".utf8)
        try sentinel.write(to: original)
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: db), databasePath: db
        )

        await viewModel.exportSingleNotePDF(makeNote(), toDirectory: output)
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Flat Note (2).pdf").path))

        await viewModel.exportSingleNotePDF(makeNote(), toDirectory: output)
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("Flat Note (3).pdf").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 3)
    }

    func test_standalonePDFShowsOriginalInlineImageInRenderedPDF() async throws {
        let dbPath = try makeFixtureDatabase()
        let png = try makeSolidPNG()
        let pngHex = png.map { String(format: "%02x", $0) }.joined()
        try executeSQL("""
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (
                ZIDENTIFIER TEXT PRIMARY KEY, ZMEDIA BLOB, ZURLSTRING TEXT, ZTITLE TEXT,
                ZALTTEXT TEXT, ZMARKEDFORDELETION INTEGER
            );
            INSERT INTO ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER, ZMEDIA, ZMARKEDFORDELETION)
                VALUES ('image-1', x'\(pngHex)', 0);
            """, databasePath: dbPath)
        let output = try makeOutputDirectory()
        let attachment = NotesAttachment(id: "image-1", typeUTI: "public.png", filename: "red-square.png")
        let html = "<html><body><p>Image marker</p><span data-attachment-id=\"image-1\" data-attachment-type=\"public.png\">[image]</span></body></html>"
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: dbPath), databasePath: dbPath
        )

        await viewModel.exportSingleNotePDF(
            makeNote(htmlBody: html, attachments: [attachment]),
            toDirectory: output
        )

        guard case .completed(let statistics) = viewModel.exportState, statistics.failedAttachments == 0,
              let pdf = PDFDocument(url: output.appendingPathComponent("Flat Note.pdf")),
              let page = pdf.page(at: 0) else {
            return XCTFail("Expected a complete PDF with its inline image")
        }
        let thumbnail = page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
        guard let tiff = thumbnail.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return XCTFail("Could not inspect the rendered PDF page")
        }
        var foundRedPixel = false
        for y in 0..<bitmap.pixelsHigh where !foundRedPixel {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.35 && color.blueComponent < 0.35 {
                    foundRedPixel = true
                    break
                }
            }
        }
        XCTAssertTrue(foundRedPixel, "The image data URI must be visibly rasterized into the final PDF")
        XCTAssertTrue(viewModel.exportLog.contains { $0.contains("Wrote standalone PDF") })
    }

    func test_standaloneProcessorLabelsFileReferencesAndExternalLinksHonestly() throws {
        XCTAssertTrue(HTMLAttachmentProcessor.isInlineImageType("com.apple.notes.gallery"),
                      "Legacy exports keep their existing gallery-as-image classification.")
        let db = try openAttachmentTestDatabase()
        defer { sqlite3_close(db) }
        let processor = HTMLAttachmentProcessor(database: db)
        let attachments = [
            NotesAttachment(id: "pdf-1", typeUTI: "public.pdf", filename: "manual.pdf"),
            NotesAttachment(id: "word-1", typeUTI: "org.openxmlformats.wordprocessingml.document", filename: "letter.docx"),
            NotesAttachment(id: "markdown-1", typeUTI: "net.daringfireball.markdown", filename: "readme.md"),
            NotesAttachment(id: "generic-1", typeUTI: "com.example.binary", filename: "data.bin"),
            NotesAttachment(id: "gallery-1", typeUTI: "com.apple.notes.gallery", filename: "Photos"),
            NotesAttachment(id: "web-link", typeUTI: "public.url", filename: "External guide"),
            NotesAttachment(id: "missing-link", typeUTI: "public.url", filename: "Missing link")
        ]
        let html = attachments.map { attachment in
            "<span data-attachment-id=\"\(attachment.id)\" data-attachment-type=\"\(attachment.typeUTI)\">[attachment]</span>"
        }.joined()
        var stagingPaths: [String: String] = [:]
        for attachment in attachments {
            stagingPaths[attachment.id] = "Attachments/\(attachment.filename ?? attachment.id)"
        }

        let result = processor.processHTML(
            html: html, attachments: attachments, attachmentPaths: stagingPaths,
            exportDirectory: "/private/tmp/controlled-staging", embedImages: true,
            linkEmbeddedImages: false, standalonePDF: true
        )

        XCTAssertEqual(result.components(separatedBy: "href=").count - 1, 1,
                       "Only the intentional external web link may remain clickable")
        XCTAssertTrue(result.contains("href=\"https://example.test/guide\""))
        XCTAssertFalse(result.contains("controlled-staging"))
        XCTAssertFalse(result.contains("Attachments/"))
        for filename in ["manual.pdf", "letter.docx", "readme.md", "data.bin"] {
            XCTAssertTrue(result.contains(filename))
            XCTAssertTrue(result.localizedCaseInsensitiveContains("not embedded"))
        }
        XCTAssertTrue(result.contains("Word Document"))
        XCTAssertTrue(result.contains("Markdown Document"))
        XCTAssertTrue(result.contains("Original gallery images not fully rendered or embedded"))
        XCTAssertTrue(result.contains("Photos"))
        XCTAssertTrue(result.contains("https://example.test/guide"))
        XCTAssertTrue(processor.notices.contains { $0.contains("not downloaded or embedded") })
        XCTAssertEqual(processor.incompleteAttachmentIDs, Set(["pdf-1", "word-1", "markdown-1", "generic-1", "gallery-1", "missing-link"]))
        XCTAssertEqual(processor.diagnostics.count, 6)
    }

    func test_standaloneProcessorReportsUnavailableImageWithoutStagingLink() throws {
        let db = try openAttachmentTestDatabase()
        defer { sqlite3_close(db) }
        let processor = HTMLAttachmentProcessor(database: db)
        let attachment = NotesAttachment(id: "missing-image", typeUTI: "public.png", filename: "gone.png")
        let html = "<span data-attachment-id=\"missing-image\" data-attachment-type=\"public.png\">[image]</span>"

        let result = processor.processHTML(
            html: html,
            attachments: [attachment],
            attachmentPaths: ["missing-image": "Attachments/gone.png"],
            exportDirectory: "/private/tmp/controlled-staging",
            embedImages: true,
            linkEmbeddedImages: false,
            standalonePDF: true
        )

        XCTAssertTrue(result.contains("Image unavailable: gone.png"))
        XCTAssertFalse(result.contains("controlled-staging"))
        XCTAssertFalse(result.contains("Attachments/gone.png"))
        XCTAssertEqual(processor.incompleteAttachmentIDs, ["missing-image"])
        XCTAssertEqual(processor.diagnostics.count, 1)
    }

    func test_unavailableInlineImageIsReportedAsPartialAndNeverLinksToStaging() async throws {
        let dbPath = try makeFixtureDatabase()
        try executeSQL("CREATE TABLE ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER TEXT PRIMARY KEY, ZMEDIA BLOB, ZMARKEDFORDELETION INTEGER);", databasePath: dbPath)
        let output = try makeOutputDirectory()
        let attachment = NotesAttachment(id: "missing-image", typeUTI: "public.png", filename: "gone.png")
        let html = "<html><body><span data-attachment-id=\"missing-image\" data-attachment-type=\"public.png\">[image]</span></body></html>"
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: dbPath), databasePath: dbPath
        )

        await viewModel.exportSingleNotePDF(
            makeNote(htmlBody: html, attachments: [attachment]),
            toDirectory: output
        )

        guard case .completed(let statistics) = viewModel.exportState else {
            return XCTFail("An unavailable attachment should still produce a partial PDF")
        }
        XCTAssertEqual(statistics.failedAttachments, 1)
        XCTAssertTrue(viewModel.exportLog.contains { $0.contains("Image unavailable") || $0.contains("incomplete in the standalone PDF") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["Flat Note.pdf"])
    }

    func test_cancelledStandaloneConversionRemovesStagingAndDoesNotDeliverPartialPDF() async throws {
        let db = try makeFixtureDatabase()
        let output = try makeOutputDirectory()
        let stagingBefore = flatPDFStagingPaths()
        let longBody = String(repeating: "<p>Cancellation checkpoint with enough text to paginate.</p>", count: 1_500)
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: db), databasePath: db
        )
        let exportTask = Task {
            await viewModel.exportSingleNotePDF(
                makeNote(htmlBody: "<html><body>\(longBody)</body></html>"),
                toDirectory: output
            )
        }

        for _ in 0..<500 {
            if viewModel.exportLog.contains(where: { $0.contains("Printing standalone PDF pages") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(viewModel.exportLog.contains { $0.contains("Printing standalone PDF pages") })
        viewModel.shouldCancel = true
        exportTask.cancel()
        await exportTask.value

        XCTAssertEqual(viewModel.exportState, .cancelled)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: output.path))?.isEmpty == true)
        XCTAssertEqual(flatPDFStagingPaths(), stagingBefore)
    }

    func test_legacyPDFExportStillCreatesItsExistingAccountAndFolderTree() async throws {
        let db = try makeFixtureDatabase()
        let output = try makeOutputDirectory()
        let viewModel = ExportViewModel(
            repository: DatabaseNotesRepository(databasePath: db), databasePath: db
        )

        await viewModel.exportNotes([makeNote()], toDirectory: output, format: .pdf)

        guard case .completed = viewModel.exportState else {
            return XCTFail("Expected the legacy PDF export path to complete")
        }
        let pdfs = (FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey]))?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pdf" } ?? []
        XCTAssertEqual(pdfs.count, 1)
        XCTAssertGreaterThan(pdfs[0].pathComponents.count, output.pathComponents.count + 1)
    }

    func test_appAndCLIProduceTheSameFilesForEveryTextFormat() async throws {
        let db = try makeFixtureDatabase()

        // The packaged formats carry timestamps and compressed streams, so they
        // never compare byte for byte; they are compared by structure in
        // test_appAndCLIProduceTheSamePackagedStructure.
        let formats = ExportFormat.allCases.filter { !$0.isBinaryFormat }

        var mismatches: [String] = []

        for format in formats {
            let appOut = try makeOutputDirectory()
            let cliOut = try makeOutputDirectory()

            try await exportViaApp(format: format, db: db, to: appOut)
            try await exportViaCLI(format: format, db: db, to: cliOut)

            let appFiles = filesUnder(appOut)
            let cliFiles = filesUnder(cliOut)

            if Set(appFiles.keys) != Set(cliFiles.keys) {
                let onlyApp = Set(appFiles.keys).subtracting(cliFiles.keys).sorted()
                let onlyCLI = Set(cliFiles.keys).subtracting(appFiles.keys).sorted()
                mismatches.append("\(format.rawValue): different files. app-only=\(onlyApp) cli-only=\(onlyCLI)")
                continue
            }

            for (path, appText) in appFiles.sorted(by: { $0.key < $1.key }) {
                let cliText = cliFiles[path] ?? ""
                if normalize(appText) != normalize(cliText) {
                    dump("\(format.rawValue)-\(path)", app: normalize(appText), cli: normalize(cliText))
                    mismatches.append("\(format.rawValue): \(path) differs\n"
                        + "  app: \(firstDifference(normalize(appText), normalize(cliText)))")
                }
            }
        }

        record(mismatches, as: "per-note")
        XCTAssertTrue(
            mismatches.isEmpty,
            "The app and the CLI disagree:\n" + mismatches.joined(separator: "\n")
        )
    }

    func test_appAndCLIAgreeOnSingleFileOutput() async throws {
        let db = try makeFixtureDatabase()
        var mismatches: [String] = []

        for format in ExportFormat.allCases where format.supportsConcatenation {
            let appOut = try makeOutputDirectory()
            let cliOut = try makeOutputDirectory()
            let single = { (c: inout ExportConfigurations) in c.concatenateOutput = true }

            try await exportViaApp(format: format, db: db, to: appOut, configure: single)
            try await exportViaCLI(format: format, db: db, to: cliOut, configure: single)

            let appFiles = filesUnder(appOut)
            let cliFiles = filesUnder(cliOut)

            guard appFiles.count == 1, cliFiles.count == 1 else {
                mismatches.append("\(format.rawValue): expected one file each, got app=\(appFiles.count) cli=\(cliFiles.count)")
                continue
            }
            let appText = normalize(appFiles.values.first ?? "")
            let cliText = normalize(cliFiles.values.first ?? "")
            if appText != cliText {
                dump("single-\(format.rawValue)", app: appText, cli: cliText)
                mismatches.append("\(format.rawValue): joined output differs\n  \(firstDifference(appText, cliText))")
            }
        }

        record(mismatches, as: "single-file")
        XCTAssertTrue(
            mismatches.isEmpty,
            "The app and the CLI disagree on Single File output:\n" + mismatches.joined(separator: "\n")
        )
    }

    /// A parity failure is a long report, and `xcodebuild`'s summary output
    /// truncates assertion messages. Write it somewhere readable too.
    /// DOCX, ODT and EPUB are zip containers whose bytes differ every run, so
    /// compare what is inside them instead: the same files, in the same places.
    ///
    /// PDF is left out. It renders through WebKit asynchronously, which makes
    /// it the one format whose output this test cannot compare cheaply — the
    /// export matrix covers it structurally instead.
    func test_appAndCLIProduceTheSamePackagedStructure() async throws {
        let db = try makeFixtureDatabase()
        var mismatches: [String] = []

        for format in ExportFormat.allCases where format.isBinaryFormat && format != .pdf {
            let appOut = try makeOutputDirectory()
            let cliOut = try makeOutputDirectory()

            try await exportViaApp(format: format, db: db, to: appOut)
            try await exportViaCLI(format: format, db: db, to: cliOut)

            let appFiles = Set(filesUnder(appOut).keys)
            let cliFiles = Set(filesUnder(cliOut).keys)
            guard appFiles == cliFiles else {
                mismatches.append("\(format.rawValue): different files. "
                    + "app-only=\(appFiles.subtracting(cliFiles).sorted()) "
                    + "cli-only=\(cliFiles.subtracting(appFiles).sorted())")
                continue
            }

            for relative in appFiles.sorted() {
                let appMembers = zipMembers(at: appOut.appendingPathComponent(relative))
                let cliMembers = zipMembers(at: cliOut.appendingPathComponent(relative))
                if appMembers.isEmpty {
                    mismatches.append("\(format.rawValue): \(relative) is not a readable zip container")
                } else if appMembers != cliMembers {
                    mismatches.append("\(format.rawValue): \(relative) holds different members. "
                        + "app-only=\(appMembers.subtracting(cliMembers).sorted()) "
                        + "cli-only=\(cliMembers.subtracting(appMembers).sorted())")
                }
            }
        }

        record(mismatches, as: "packaged")
        XCTAssertTrue(
            mismatches.isEmpty,
            "The app and the CLI disagree on packaged output:\n" + mismatches.joined(separator: "\n")
        )
    }

    /// The names of the files inside a zip container, or empty if it is not one.
    private func zipMembers(at url: URL) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init))
    }

    /// Write the two outputs side by side so a mismatch can be inspected with
    /// a real diff tool rather than read out of an assertion message.
    private func dump(_ label: String, app: String, cli: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ane-parity-dumps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = label.replacingOccurrences(of: "/", with: "_")
        try? app.write(to: dir.appendingPathComponent("\(safe).app.txt"), atomically: true, encoding: .utf8)
        try? cli.write(to: dir.appendingPathComponent("\(safe).cli.txt"), atomically: true, encoding: .utf8)
    }

    private func record(_ mismatches: [String], as name: String) {
        guard !mismatches.isEmpty else { return }
        let report = mismatches.joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ane-parity-\(name).txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)
        print("PARITY REPORT (\(name)) written to \(url.path); "
            + "the two outputs for each mismatch are in "
            + "\(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ane-parity-dumps").path)"
            + "\n\(report)")
    }

    /// Describe how two outputs differ.
    ///
    /// Reports the lines present in one and not the other rather than a
    /// position-by-position diff: a single extra line near the top shifts
    /// everything below it and makes a positional diff read as total
    /// disagreement.
    private func firstDifference(_ a: String, _ b: String) -> String {
        let aLines = a.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let bLines = b.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let onlyApp = Array(Set(aLines).subtracting(bLines)).filter { !$0.isEmpty }.sorted()
        let onlyCLI = Array(Set(bLines).subtracting(aLines)).filter { !$0.isEmpty }.sorted()

        var parts: [String] = ["lines app=\(aLines.count) cli=\(bLines.count)"]
        if !onlyApp.isEmpty {
            parts.append("  only in app (\(onlyApp.count)): " + onlyApp.prefix(4).map { String($0.prefix(120)) }.joined(separator: " | "))
        }
        if !onlyCLI.isEmpty {
            parts.append("  only in cli (\(onlyCLI.count)): " + onlyCLI.prefix(4).map { String($0.prefix(120)) }.joined(separator: " | "))
        }
        if onlyApp.isEmpty && onlyCLI.isEmpty {
            parts.append("  same lines, different order or whitespace")
        }
        return parts.joined(separator: "\n")
    }
}
