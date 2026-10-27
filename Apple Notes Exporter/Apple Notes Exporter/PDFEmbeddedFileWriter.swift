//
// PDFEmbeddedFileWriter.swift
//
// Adds PDF attachments to the document-level EmbeddedFiles name tree. The note
// pages produced by WebKit are retained byte-for-byte as the prefix of an
// incremental PDF update; attachment pages are never copied into the page tree.
//

import Foundation
import PDFKit

struct PDFEmbeddedFileWriteResult {
    let pageCount: Int
    let embeddedFileCount: Int
}

enum PDFEmbeddedFileWriterError: Error, LocalizedError {
    case invalidSourcePDF
    case unsupportedCrossReferenceFormat
    case malformedPDFStructure(String)
    case encryptedPDF
    case existingEmbeddedFiles
    case attachmentTooLarge(String)
    case totalAttachmentBytesExceeded
    case conflictingDuplicateAttachment(String)
    case unableToWrite
    case invalidOutputPDF

    var errorDescription: String? {
        switch self {
        case .invalidSourcePDF:
            return "The generated note PDF is invalid and cannot safely receive embedded attachments."
        case .unsupportedCrossReferenceFormat:
            return "The generated PDF uses a cross-reference format that the safe attachment writer does not support. No export was written."
        case .malformedPDFStructure(let detail):
            return "The generated PDF has an unsupported or malformed structure: \(detail)"
        case .encryptedPDF:
            return "The generated note PDF is encrypted; embedded attachments were not added."
        case .existingEmbeddedFiles:
            return "The generated PDF already contains embedded files; refusing to replace or duplicate them."
        case .attachmentTooLarge(let name):
            return "PDF attachment ‘\(name)’ exceeds the 96 MiB per-file safety limit and was not embedded."
        case .totalAttachmentBytesExceeded:
            return "PDF attachments exceed the 256 MiB total safety limit and were not embedded."
        case .conflictingDuplicateAttachment(let name):
            return "Attachment ID for ‘\(name)’ referred to different bytes; refusing an ambiguous export."
        case .unableToWrite:
            return "The PDF with embedded attachments could not be written safely."
        case .invalidOutputPDF:
            return "The PDF with embedded attachments failed its integrity check."
        }
    }
}

/// Writes standard PDF file specifications and an EmbeddedFiles name tree using
/// a classic incremental cross-reference update. The current exporter creates
/// its note PDFs through WebKit/AppKit printing (classic xref table, unencrypted
/// PDF); unsupported structures fail closed rather than producing a partial file.
enum PDFEmbeddedFileWriter {
    static let maximumAttachmentBytes = 96 * 1024 * 1024
    static let maximumTotalAttachmentBytes = 256 * 1024 * 1024

    private struct Reference {
        let objectNumber: Int
        let generation: Int

        var pdf: String { "\(objectNumber) \(generation) R" }
    }

    private struct XrefEntry {
        let offset: Int
        let generation: Int
        let isInUse: Bool
    }

    private struct DictionaryEntry {
        let name: String
        let keyRange: Range<Int>
        let valueRange: Range<Int>
    }

    private struct ParsedDictionary {
        let range: Range<Int>
        let closingRange: Range<Int>
        let entries: [DictionaryEntry]

        func entries(named name: String) -> [DictionaryEntry] {
            entries.filter { $0.name == name }
        }
    }

    private struct XrefSection {
        let trailer: ParsedDictionary
        let entries: [Int: XrefEntry]
    }

    private struct ObjectToWrite {
        let reference: Reference
        let body: Data
    }

    private struct UniqueAttachment {
        let attachmentID: String
        let filename: String
        let data: Data
        let treeKey: String
    }

    private struct ByteCursor {
        let data: Data
        var offset: Int

        init(data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }

        var isAtEnd: Bool { offset >= data.count }

        mutating func skipTrivia() {
            while offset < data.count {
                let byte = data[offset]
                if Self.isWhitespace(byte) {
                    offset += 1
                } else if byte == 0x25 { // % comment
                    while offset < data.count && data[offset] != 0x0A && data[offset] != 0x0D {
                        offset += 1
                    }
                } else {
                    break
                }
            }
        }

        mutating func readToken() -> (String, Range<Int>)? {
            skipTrivia()
            guard offset < data.count else { return nil }
            let start = offset
            while offset < data.count && !Self.isWhitespace(data[offset]) && !Self.isDelimiter(data[offset]) {
                offset += 1
            }
            guard offset > start else { return nil }
            return (String(decoding: data[start..<offset], as: UTF8.self), start..<offset)
        }

        mutating func readName() -> (String, Range<Int>)? {
            skipTrivia()
            guard offset < data.count, data[offset] == 0x2F else { return nil }
            let start = offset
            offset += 1
            var decoded: [UInt8] = []
            while offset < data.count && !Self.isWhitespace(data[offset]) && !Self.isDelimiter(data[offset]) {
                if data[offset] == 0x23, offset + 2 < data.count,
                   let high = Self.hexValue(data[offset + 1]), let low = Self.hexValue(data[offset + 2]) {
                    decoded.append((high << 4) | low)
                    offset += 3
                } else {
                    decoded.append(data[offset])
                    offset += 1
                }
            }
            return (String(decoding: decoded, as: UTF8.self), start..<offset)
        }

        mutating func readValueRange() throws -> Range<Int> {
            skipTrivia()
            guard offset < data.count else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("missing dictionary value") }
            let start = offset
            switch data[offset] {
            case 0x28: // literal string, including nested parentheses
                offset += 1
                var depth = 1
                while offset < data.count && depth > 0 {
                    let byte = data[offset]
                    if byte == 0x5C { // backslash escape
                        offset += 1
                        if offset < data.count { offset += 1 }
                    } else {
                        if byte == 0x28 { depth += 1 }
                        if byte == 0x29 { depth -= 1 }
                        offset += 1
                    }
                }
                guard depth == 0 else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("unterminated literal string") }
                return start..<offset
            case 0x3C:
                if offset + 1 < data.count, data[offset + 1] == 0x3C {
                    _ = try readDictionary()
                    return start..<offset
                }
                offset += 1
                while offset < data.count && data[offset] != 0x3E { offset += 1 }
                guard offset < data.count else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("unterminated hex string") }
                offset += 1
                return start..<offset
            case 0x5B: // array
                offset += 1
                while true {
                    skipTrivia()
                    guard offset < data.count else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("unterminated array") }
                    if data[offset] == 0x5D {
                        offset += 1
                        return start..<offset
                    }
                    _ = try readValueRange()
                }
            case 0x2F: // name
                guard readName() != nil else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid PDF name") }
                return start..<offset
            default:
                guard let first = readToken() else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid PDF value") }
                let firstEnd = offset
                if Int(first.0) != nil,
                   let second = readToken(), Int(second.0) != nil,
                   let third = readToken(), third.0 == "R" {
                    return start..<offset
                }
                offset = firstEnd
                return start..<offset
            }
        }

        mutating func readDictionary() throws -> ParsedDictionary {
            skipTrivia()
            let start = offset
            guard offset + 1 < data.count, data[offset] == 0x3C, data[offset + 1] == 0x3C else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("expected a dictionary")
            }
            offset += 2
            var entries: [DictionaryEntry] = []
            while true {
                skipTrivia()
                guard offset + 1 < data.count else {
                    throw PDFEmbeddedFileWriterError.malformedPDFStructure("unterminated dictionary")
                }
                if data[offset] == 0x3E && data[offset + 1] == 0x3E {
                    let closing = offset..<offset + 2
                    offset += 2
                    return ParsedDictionary(range: start..<offset, closingRange: closing, entries: entries)
                }
                guard let (name, keyRange) = readName() else {
                    throw PDFEmbeddedFileWriterError.malformedPDFStructure("dictionary key is not a PDF name")
                }
                let valueRange = try readValueRange()
                entries.append(DictionaryEntry(name: name, keyRange: keyRange, valueRange: valueRange))
            }
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
        }

        private static func isDelimiter(_ byte: UInt8) -> Bool {
            byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E || byte == 0x5B || byte == 0x5D || byte == 0x7B || byte == 0x7D || byte == 0x2F || byte == 0x25
        }

        private static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
    }

    @discardableResult
    static func addAttachments(
        _ insertions: [PDFHTMLAttachmentInsertion],
        to inputURL: URL,
        writingTo outputURL: URL,
        cancellationCheck: () throws -> Void = {}
    ) throws -> PDFEmbeddedFileWriteResult {
        guard let inputDocument = PDFDocument(url: inputURL), !inputDocument.isLocked, inputDocument.pageCount > 0 else {
            throw PDFEmbeddedFileWriterError.invalidSourcePDF
        }
        let sourcePageCount = inputDocument.pageCount
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        } catch {
            throw PDFEmbeddedFileWriterError.invalidSourcePDF
        }

        let unique = try uniqueAttachments(from: insertions)
        guard !unique.isEmpty else {
            try FileManager.default.copyItem(at: inputURL, to: outputURL)
            return PDFEmbeddedFileWriteResult(pageCount: sourcePageCount, embeddedFileCount: 0)
        }
        let structure = try parseStructure(sourceData)
        guard structure.trailer.entries(named: "Encrypt").isEmpty else {
            throw PDFEmbeddedFileWriterError.encryptedPDF
        }
        guard structure.trailer.entries(named: "XRefStm").isEmpty else {
            throw PDFEmbeddedFileWriterError.unsupportedCrossReferenceFormat
        }

        let rootValue = try valueData(sourceData, structure.trailer.entries(named: "Root").first)
        let rootReference = try parseReference(rootValue)
        guard let rootLocation = try findObject(rootReference, in: structure, sourceData: sourceData) else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("the catalog object is missing from the cross-reference chain")
        }
        let rootObject = try parseObject(at: rootLocation, expected: rootReference, in: sourceData)
        let rootNamesEntries = rootObject.dictionary.entries(named: "Names")
        guard rootNamesEntries.count <= 1 else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("the catalog contains duplicate Names entries")
        }

        var nextObjectNumber = structure.size
        var updates: [ObjectToWrite] = []
        var attachmentReferences: [(String, Reference)] = []
        for attachment in unique {
            try cancellationCheck()
            let streamReference = Reference(objectNumber: nextObjectNumber, generation: 0)
            nextObjectNumber += 1
            let fileSpecReference = Reference(objectNumber: nextObjectNumber, generation: 0)
            nextObjectNumber += 1

            var stream = Data(ascii: "<< /Type /EmbeddedFile /Subtype /application#2Fpdf /Params << /Size \(attachment.data.count) >> /Length \(attachment.data.count) >>\nstream\n")
            stream.append(attachment.data)
            stream.append(Data(ascii: "\nendstream"))
            updates.append(ObjectToWrite(reference: streamReference, body: stream))

            let filenameString = Self.pdfTextString(attachment.filename)
            let descriptionString = Self.pdfTextString("PDF attachment: \(attachment.filename)")
            let fileSpec = "<< /Type /Filespec /F \(filenameString) /UF \(filenameString) /Desc \(descriptionString) /EF << /F \(streamReference.pdf) /UF \(streamReference.pdf) >> >>"
            updates.append(ObjectToWrite(reference: fileSpecReference, body: Data(ascii: fileSpec)))
            attachmentReferences.append((attachment.treeKey, fileSpecReference))
        }

        attachmentReferences.sort { Self.pdfTextString($0.0).lexicographicallyPrecedes(Self.pdfTextString($1.0)) }
        let namesArray = attachmentReferences.map { "\(Self.pdfTextString($0.0)) \($0.1.pdf)" }.joined(separator: " ")
        let limits = attachmentReferences.first.map { first in
            attachmentReferences.last.map { last in " /Limits [\(Self.pdfTextString(first.0)) \(Self.pdfTextString(last.0))]" } ?? ""
        } ?? ""
        let embeddedFilesTreeReference = Reference(objectNumber: nextObjectNumber, generation: 0)
        nextObjectNumber += 1
        updates.append(ObjectToWrite(
            reference: embeddedFilesTreeReference,
            body: Data(ascii: "<< /Names [\(namesArray)]\(limits) >>")
        ))

        var rootReplacements: [String: Data] = [:]
        var rootAdditions: [(String, Data)] = []
        if let namesEntry = rootNamesEntries.first {
            let namesValue = Data(sourceData[namesEntry.valueRange])
            if let namesReference = try parseOptionalReference(namesValue) {
                guard let namesLocation = try findObject(namesReference, in: structure, sourceData: sourceData) else {
                    throw PDFEmbeddedFileWriterError.malformedPDFStructure("the Names object is missing")
                }
                let namesObject = try parseObject(at: namesLocation, expected: namesReference, in: sourceData)
                guard namesObject.dictionary.entries(named: "EmbeddedFiles").isEmpty else {
                    throw PDFEmbeddedFileWriterError.existingEmbeddedFiles
                }
                let patchedNames = try patchDictionary(
                    sourceData,
                    namesObject.dictionary,
                    replacements: [:],
                    additions: [("EmbeddedFiles", Data(ascii: embeddedFilesTreeReference.pdf))]
                )
                updates.append(ObjectToWrite(reference: namesReference, body: patchedNames))
            } else if let namesDictionary = try parseOptionalDictionary(sourceData, namesEntry.valueRange) {
                guard namesDictionary.entries(named: "EmbeddedFiles").isEmpty else {
                    throw PDFEmbeddedFileWriterError.existingEmbeddedFiles
                }
                let namesReference = Reference(objectNumber: nextObjectNumber, generation: 0)
                nextObjectNumber += 1
                let patchedNames = try patchDictionary(
                    sourceData,
                    namesDictionary,
                    replacements: [:],
                    additions: [("EmbeddedFiles", Data(ascii: embeddedFilesTreeReference.pdf))]
                )
                updates.append(ObjectToWrite(reference: namesReference, body: patchedNames))
                rootReplacements["Names"] = Data(ascii: namesReference.pdf)
            } else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("the catalog Names entry is neither a dictionary nor an indirect reference")
            }
        } else {
            let namesReference = Reference(objectNumber: nextObjectNumber, generation: 0)
            nextObjectNumber += 1
            let namesDictionary = Data(ascii: "<< /EmbeddedFiles \(embeddedFilesTreeReference.pdf) >>")
            updates.append(ObjectToWrite(reference: namesReference, body: namesDictionary))
            rootAdditions.append(("Names", Data(ascii: namesReference.pdf)))
        }

        let versionEntries = rootObject.dictionary.entries(named: "Version")
        guard versionEntries.count <= 1 else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("the catalog contains duplicate Version entries")
        }
        if try catalogNeedsPDF14Version(rootVersionEntry: versionEntries.first, sourceData: sourceData) {
            if versionEntries.isEmpty {
                rootAdditions.append(("Version", Data(ascii: "/1.4")))
            } else {
                rootReplacements["Version"] = Data(ascii: "/1.4")
            }
        }
        let patchedRoot = try patchDictionary(
            sourceData,
            rootObject.dictionary,
            replacements: rootReplacements,
            additions: rootAdditions
        )
        updates.append(ObjectToWrite(reference: rootReference, body: patchedRoot))

        guard nextObjectNumber > 0 else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid object count") }
        try writeIncrementalUpdate(
            inputURL: inputURL,
            outputURL: outputURL,
            sourceData: sourceData,
            sourceTrailer: structure.trailer,
            updates: updates,
            latestXrefOffset: structure.latestXrefOffset,
            rootReference: rootReference,
            size: nextObjectNumber,
            cancellationCheck: cancellationCheck
        )

        guard let outputDocument = PDFDocument(url: outputURL), !outputDocument.isLocked,
              outputDocument.pageCount == sourcePageCount else {
            try? FileManager.default.removeItem(at: outputURL)
            throw PDFEmbeddedFileWriterError.invalidOutputPDF
        }
        return PDFEmbeddedFileWriteResult(pageCount: outputDocument.pageCount, embeddedFileCount: unique.count)
    }

    private static func uniqueAttachments(from insertions: [PDFHTMLAttachmentInsertion]) throws -> [UniqueAttachment] {
        var byID: [String: (String, Data)] = [:]
        var ordered: [(String, String, Data)] = []
        var totalBytes = 0
        for insertion in insertions {
            guard insertion.data.count <= maximumAttachmentBytes else {
                throw PDFEmbeddedFileWriterError.attachmentTooLarge(insertion.filename)
            }
            if let existing = byID[insertion.attachmentID] {
                guard existing.1 == insertion.data else {
                    throw PDFEmbeddedFileWriterError.conflictingDuplicateAttachment(insertion.filename)
                }
                continue
            }
            let total = totalBytes.addingReportingOverflow(insertion.data.count)
            guard !total.overflow, total.partialValue <= maximumTotalAttachmentBytes else {
                throw PDFEmbeddedFileWriterError.totalAttachmentBytesExceeded
            }
            totalBytes = total.partialValue
            byID[insertion.attachmentID] = (insertion.filename, insertion.data)
            ordered.append((insertion.attachmentID, Self.safeFilename(insertion.filename), insertion.data))
        }

        var usedKeys = Set<String>()
        return ordered.map { id, filename, data in
            var key = filename
            var suffix = 2
            while !usedKeys.insert(key).inserted {
                let url = URL(fileURLWithPath: filename)
                let ext = url.pathExtension
                let stem = ext.isEmpty ? filename : url.deletingPathExtension().lastPathComponent
                key = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
                suffix += 1
            }
            return UniqueAttachment(attachmentID: id, filename: filename, data: data, treeKey: key)
        }
    }

    private static func safeFilename(_ input: String) -> String {
        let last = URL(fileURLWithPath: input.isEmpty ? "Attachment.pdf" : input).lastPathComponent
        let filtered = String(last.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "/" && scalar != "\\"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty || filtered == "." || filtered == ".." ? "Attachment.pdf" : filtered
    }

    private static func pdfTextString(_ string: String) -> String {
        var bytes = Data([0xFE, 0xFF])
        for unit in string.utf16 {
            bytes.append(UInt8((unit >> 8) & 0xFF))
            bytes.append(UInt8(unit & 0xFF))
        }
        return "<" + bytes.map { String(format: "%02X", Int($0)) }.joined() + ">"
    }

    /// EmbeddedFiles is a PDF 1.4 feature. If the file header (or an explicit
    /// catalog version override) is older, set the catalog override to the
    /// minimum version required for the name tree we add.
    private static func catalogNeedsPDF14Version(
        rootVersionEntry: DictionaryEntry?,
        sourceData: Data
    ) throws -> Bool {
        let versionText: String
        if let rootVersionEntry {
            versionText = String(decoding: sourceData[rootVersionEntry.valueRange], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            guard sourceData.starts(with: Data("%PDF-".utf8)), sourceData.count >= 8 else {
                throw PDFEmbeddedFileWriterError.invalidSourcePDF
            }
            versionText = String(decoding: sourceData[5..<8], as: UTF8.self)
        }
        let components = versionText.split(separator: ".")
        guard components.count == 2,
              let major = Int(components[0]), let minor = Int(components[1]),
              major >= 1, minor >= 0 else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("the PDF version could not be determined")
        }
        return major < 1 || (major == 1 && minor < 4)
    }

    private static func parseStructure(_ data: Data) throws -> (latestXrefOffset: Int, trailer: ParsedDictionary, size: Int) {
        guard let marker = data.range(of: Data("startxref".utf8), options: .backwards) else {
            throw PDFEmbeddedFileWriterError.unsupportedCrossReferenceFormat
        }
        var cursor = ByteCursor(data: data, offset: marker.upperBound)
        guard let offsetToken = cursor.readToken(), let xrefOffset = Int(offsetToken.0), xrefOffset >= 0, xrefOffset < data.count else {
            throw PDFEmbeddedFileWriterError.unsupportedCrossReferenceFormat
        }
        var currentOffset = xrefOffset
        var visited = Set<Int>()
        var latest: XrefSection?
        while true {
            guard visited.insert(currentOffset).inserted, visited.count <= 32 else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("cyclic or excessively long cross-reference chain")
            }
            let section = try parseXrefTable(at: currentOffset, in: data)
            if latest == nil { latest = section }
            guard let previousEntry = section.trailer.entries(named: "Prev").first else { break }
            let previousData = try valueData(data, previousEntry)
            guard let previousOffset = Int(String(decoding: previousData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  previousOffset >= 0, previousOffset < data.count else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid Prev cross-reference offset")
            }
            currentOffset = previousOffset
        }
        guard let latest,
              let sizeEntry = latest.trailer.entries(named: "Size").first,
              let size = Int(String(decoding: try valueData(data, sizeEntry), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              size > 0 else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("missing or invalid Size in trailer")
        }
        return (xrefOffset, latest.trailer, size)
    }

    private static func parseXrefTable(at offset: Int, in data: Data) throws -> XrefSection {
        var cursor = ByteCursor(data: data, offset: offset)
        guard cursor.readToken()?.0 == "xref" else {
            throw PDFEmbeddedFileWriterError.unsupportedCrossReferenceFormat
        }
        var entries: [Int: XrefEntry] = [:]
        while let token = cursor.readToken()?.0 {
            if token == "trailer" {
                let dictionary = try cursor.readDictionary()
                return XrefSection(trailer: dictionary, entries: entries)
            }
            guard let firstObject = Int(token),
                  let countToken = cursor.readToken()?.0, let count = Int(countToken),
                  firstObject >= 0, count >= 0, count <= 5_000_000 else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid cross-reference subsection")
            }
            for objectNumber in firstObject..<(firstObject + count) {
                guard let offsetText = cursor.readToken()?.0, let objectOffset = Int(offsetText),
                      let generationText = cursor.readToken()?.0, let generation = Int(generationText),
                      let flag = cursor.readToken()?.0, flag == "n" || flag == "f" else {
                    throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid cross-reference entry")
                }
                entries[objectNumber] = XrefEntry(offset: objectOffset, generation: generation, isInUse: flag == "n")
            }
        }
        throw PDFEmbeddedFileWriterError.malformedPDFStructure("cross-reference table has no trailer")
    }

    private static func findObject(
        _ reference: Reference,
        in structure: (latestXrefOffset: Int, trailer: ParsedDictionary, size: Int),
        sourceData: Data
    ) throws -> Int? {
        var currentOffset = structure.latestXrefOffset
        var visited = Set<Int>()
        while true {
            guard visited.insert(currentOffset).inserted, visited.count <= 32 else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("cyclic cross-reference chain")
            }
            let section = try parseXrefTable(at: currentOffset, in: sourceData)
            if let entry = section.entries[reference.objectNumber] {
                guard entry.isInUse, entry.generation == reference.generation else { return nil }
                return entry.offset
            }
            guard let previousEntry = section.trailer.entries(named: "Prev").first else { return nil }
            let previousData = try valueData(sourceData, previousEntry)
            guard let previousOffset = Int(String(decoding: previousData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("invalid Prev cross-reference offset")
            }
            currentOffset = previousOffset
        }
    }

    private static func parseObject(at offset: Int, expected reference: Reference, in data: Data) throws -> (dictionary: ParsedDictionary, objectRange: Range<Int>) {
        var cursor = ByteCursor(data: data, offset: offset)
        guard let objectNumberToken = cursor.readToken()?.0,
              let objectNumber = Int(objectNumberToken),
              let generationToken = cursor.readToken()?.0,
              let generation = Int(generationToken),
              cursor.readToken()?.0 == "obj",
              objectNumber == reference.objectNumber, generation == reference.generation else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("cross-reference points to the wrong object")
        }
        let dictionary = try cursor.readDictionary()
        return (dictionary, offset..<cursor.offset)
    }

    private static func valueData(_ data: Data, _ entry: DictionaryEntry?) throws -> Data {
        guard let entry else { throw PDFEmbeddedFileWriterError.malformedPDFStructure("required dictionary entry is missing") }
        return Data(data[entry.valueRange])
    }

    private static func parseReference(_ data: Data) throws -> Reference {
        guard let reference = try parseOptionalReference(data) else {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("expected an indirect object reference")
        }
        return reference
    }

    private static func parseOptionalReference(_ data: Data) throws -> Reference? {
        var cursor = ByteCursor(data: data)
        guard let first = cursor.readToken()?.0, let objectNumber = Int(first),
              let second = cursor.readToken()?.0, let generation = Int(second),
              cursor.readToken()?.0 == "R" else { return nil }
        cursor.skipTrivia()
        guard cursor.isAtEnd else { return nil }
        return Reference(objectNumber: objectNumber, generation: generation)
    }

    private static func parseOptionalDictionary(_ data: Data, _ range: Range<Int>) throws -> ParsedDictionary? {
        var cursor = ByteCursor(data: data, offset: range.lowerBound)
        cursor.skipTrivia()
        guard cursor.offset + 1 < data.count, data[cursor.offset] == 0x3C, data[cursor.offset + 1] == 0x3C else { return nil }
        let dictionary = try cursor.readDictionary()
        cursor.skipTrivia()
        guard cursor.offset == range.upperBound else { return nil }
        return dictionary
    }

    private static func patchDictionary(
        _ data: Data,
        _ dictionary: ParsedDictionary,
        replacements: [String: Data],
        additions: [(String, Data)]
    ) throws -> Data {
        for (name, _) in replacements where dictionary.entries(named: name).count != 1 {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("cannot safely replace \(name) dictionary entry")
        }
        for (name, _) in additions where !dictionary.entries(named: name).isEmpty {
            throw PDFEmbeddedFileWriterError.malformedPDFStructure("refusing to duplicate \(name) dictionary entry")
        }
        let replacementEntries = dictionary.entries.filter { replacements[$0.name] != nil }.sorted { $0.valueRange.lowerBound < $1.valueRange.lowerBound }
        var result = Data()
        var cursor = dictionary.range.lowerBound
        for entry in replacementEntries {
            result.append(data[cursor..<entry.valueRange.lowerBound])
            result.append(replacements[entry.name]!)
            cursor = entry.valueRange.upperBound
        }
        result.append(data[cursor..<dictionary.closingRange.lowerBound])
        for (name, value) in additions {
            result.append(Data(ascii: "\n/\(name) "))
            result.append(value)
        }
        result.append(Data(ascii: "\n>>"))
        return result
    }

    private static func writeIncrementalUpdate(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        sourceTrailer: ParsedDictionary,
        updates: [ObjectToWrite],
        latestXrefOffset: Int,
        rootReference: Reference,
        size: Int,
        cancellationCheck: () throws -> Void
    ) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PDFEmbeddedFileWriterError.unableToWrite
        }
        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".pdf-attachments-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partialURL) }

        do {
            try FileManager.default.copyItem(at: inputURL, to: partialURL)
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var offsets: [Int: XrefEntry] = [:]
            for object in updates {
                try cancellationCheck()
                let currentOffset = try handle.offset()
                guard currentOffset <= UInt64(Int.max) else { throw PDFEmbeddedFileWriterError.unableToWrite }
                offsets[object.reference.objectNumber] = XrefEntry(
                    offset: Int(currentOffset), generation: object.reference.generation, isInUse: true
                )
                try handle.write(contentsOf: Data(ascii: "\n\(object.reference.objectNumber) \(object.reference.generation) obj\n"))
                try handle.write(contentsOf: object.body)
                try handle.write(contentsOf: Data(ascii: "\nendobj\n"))
            }
            try cancellationCheck()
            var trailerReplacements: [String: Data] = [
                "Size": Data(ascii: "\(size)"),
                "Root": Data(ascii: rootReference.pdf)
            ]
            var trailerAdditions: [(String, Data)] = []
            let previousEntries = sourceTrailer.entries(named: "Prev")
            guard previousEntries.count <= 1 else {
                throw PDFEmbeddedFileWriterError.malformedPDFStructure("the trailer contains duplicate Prev entries")
            }
            if previousEntries.isEmpty {
                trailerAdditions.append(("Prev", Data(ascii: "\(latestXrefOffset)")))
            } else {
                trailerReplacements["Prev"] = Data(ascii: "\(latestXrefOffset)")
            }
            let updatedTrailer = try Self.patchDictionary(
                sourceData,
                sourceTrailer,
                replacements: trailerReplacements,
                additions: trailerAdditions
            )
            let xrefOffsetValue = try handle.offset()
            guard xrefOffsetValue <= UInt64(Int.max) else { throw PDFEmbeddedFileWriterError.unableToWrite }
            let xrefOffset = Int(xrefOffsetValue)
            try handle.write(contentsOf: Data(ascii: "xref\n"))
            let sortedObjectNumbers = offsets.keys.sorted()
            var position = 0
            while position < sortedObjectNumbers.count {
                let first = sortedObjectNumbers[position]
                var end = position + 1
                while end < sortedObjectNumbers.count && sortedObjectNumbers[end] == sortedObjectNumbers[end - 1] + 1 {
                    end += 1
                }
                try handle.write(contentsOf: Data(ascii: "\(first) \(end - position)\n"))
                for number in sortedObjectNumbers[position..<end] {
                    guard let entry = offsets[number], entry.offset >= 0 else { throw PDFEmbeddedFileWriterError.unableToWrite }
                    try handle.write(contentsOf: Data(ascii: Self.xrefLine(offset: entry.offset, generation: entry.generation)))
                }
                position = end
            }
            try handle.write(contentsOf: Data(ascii: "trailer\n"))
            try handle.write(contentsOf: updatedTrailer)
            try handle.write(contentsOf: Data(ascii: "\nstartxref\n\(xrefOffset)\n%%EOF\n"))
            try handle.synchronize()
            try handle.close()
            try FileManager.default.moveItem(at: partialURL, to: outputURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PDFEmbeddedFileWriterError {
            throw error
        } catch {
            throw PDFEmbeddedFileWriterError.unableToWrite
        }
    }

    private static func xrefLine(offset: Int, generation: Int) -> String {
        let offsetText = String(offset)
        let paddedOffset = String(repeating: "0", count: max(0, 10 - offsetText.count)) + offsetText
        let generationText = String(generation)
        let paddedGeneration = String(repeating: "0", count: max(0, 5 - generationText.count)) + generationText
        return "\(paddedOffset) \(paddedGeneration) n \n"
    }
}

private extension Data {
    init(ascii string: String) {
        self = Data(string.utf8)
    }
}
