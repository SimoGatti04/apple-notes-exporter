//
//  HTMLAttachmentProcessor.swift
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

import Foundation
import SQLite3
import OSLog
import AppKit

struct AttachmentMarkerFallbackResult {
    let html: String
    let incompleteAttachmentIDs: Set<String>
    let diagnostics: [String]
}

/// Processes HTML to replace attachment placeholders with inline content or links
class HTMLAttachmentProcessor {
    private let db: OpaquePointer
    private let tableParser: TableParser
    private var exportDirectory: String?

    /// Attachments whose content could not be represented inside a standalone PDF.
    private(set) var incompleteAttachmentIDs: Set<String> = []
    /// User-visible export warnings, suitable for the export log.
    private(set) var diagnostics: [String] = []
    /// Informational notes that clarify external references without counting
    /// them as failed attachment preservation.
    private(set) var notices: [String] = []

    init(database: OpaquePointer) {
        self.db = database
        self.tableParser = TableParser(database: database)
    }

    static func containsAttachmentMarkers(in html: String) -> Bool {
        let pattern = #"<span\s+data-attachment-id="([^"]+)"\s+data-attachment-type="([^"]+)">.*?</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return false
        }
        return regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    /// Replace attachment markers without consulting the Notes database. This
    /// is used only when the database cannot be opened; in particular, an
    /// unvalidated ID is never used to fetch attachment bytes.
    static func replaceUnavailableMarkersWithoutDatabase(
        in html: String,
        attachments: [NotesAttachment],
        reason: String
    ) -> AttachmentMarkerFallbackResult {
        let pattern = #"<span\s+data-attachment-id="([^"]+)"\s+data-attachment-type="([^"]+)">.*?</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return AttachmentMarkerFallbackResult(html: html, incompleteAttachmentIDs: [], diagnostics: [])
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var attachmentMap: [String: NotesAttachment] = [:]
        for attachment in attachments where attachmentMap[attachment.id] == nil {
            // Preserve the first occurrence deterministically. Partially
            // decoded or damaged stores may contain duplicate identifiers.
            attachmentMap[attachment.id] = attachment
        }
        var result = html
        var incompleteIDs = Set<String>()
        var diagnostics: [String] = []

        for match in matches.reversed() where match.numberOfRanges >= 3 {
            let fullRange = match.range(at: 0)
            let identifier = source.substring(with: match.range(at: 1))
            let typeUTI = source.substring(with: match.range(at: 2))
            let attachment = attachmentMap[identifier]
            let label = attachment?.filename ?? attachment?.name ?? "Attachment \(identifier)"
            let isUnverified = attachment == nil
            let detail = isUnverified
                ? "Ownership could not be verified; original content was not accessed"
                : "The source database was unavailable; original content was not accessed"
            let reference = standaloneFileReferenceHTML(
                filename: label,
                description: detail
            )
            result = (result as NSString).replacingCharacters(in: fullRange, with: reference)

            if incompleteIDs.insert(identifier).inserted {
                let safetyNote = isUnverified ? " No attachment bytes were read." : ""
                diagnostics.append("Attachment '\(label)' (\(typeUTI)) is incomplete in the standalone PDF: \(reason).\(safetyNote)")
            }
        }

        return AttachmentMarkerFallbackResult(
            html: result,
            incompleteAttachmentIDs: incompleteIDs,
            diagnostics: diagnostics
        )
    }

    static func isInlineImageType(_ typeUTI: String) -> Bool {
        typeUTI.hasPrefix("public.image") ||
        typeUTI.hasPrefix("public.jpeg") ||
        typeUTI.hasPrefix("public.png") ||
        typeUTI.hasPrefix("public.heic") ||
        typeUTI.hasPrefix("public.tiff") ||
        typeUTI.hasPrefix("com.compuserve.gif") ||
        typeUTI == "com.apple.paper" ||
        typeUTI == "com.apple.drawing" ||
        typeUTI == "com.apple.drawing.2" ||
        typeUTI == "com.apple.notes.gallery"
    }

    /// Process HTML to replace attachment markers with actual content
    /// - Parameters:
    ///   - html: Raw HTML from the database
    ///   - attachments: List of attachments for this note
    ///   - attachmentPaths: Map of attachment IDs to relative file paths
    ///   - exportDirectory: Base directory where files are being exported (for resolving relative paths)
    ///   - embedImages: Whether to embed images inline as base64
    ///   - linkEmbeddedImages: Whether to wrap embedded images in <a> tags linking to files
    /// - Returns: Processed HTML with attachments replaced
    func processHTML(
        html: String,
        attachments: [NotesAttachment],
        attachmentPaths: [String: String],
        exportDirectory: String? = nil,
        embedImages: Bool,
        linkEmbeddedImages: Bool,
        standalonePDF: Bool = false
    ) -> String {
        // Store export directory for later use
        self.exportDirectory = exportDirectory

        var processedHTML = html

        // Create attachment lookup by ID
        var attachmentMap: [String: NotesAttachment] = [:]
        for attachment in attachments {
            attachmentMap[attachment.id] = attachment
        }

        // Find and replace attachment markers
        // Pattern matches: [Attachment: <type>] or object-replacement-character followed by attachment
        // For now, we'll look for the object replacement character (U+FFFC) which Apple Notes uses

        // First, try to match object replacement characters which might be followed by attachment data
        // In Apple Notes HTML, attachments are often represented by <object> tags
        processedHTML = replaceObjectTags(
            in: processedHTML,
            attachmentMap: attachmentMap,
            attachmentPaths: attachmentPaths,
            embedImages: embedImages,
            linkEmbeddedImages: linkEmbeddedImages,
            standalonePDF: standalonePDF
        )

        if standalonePDF {
            let represented = representedAttachmentIDs(in: html)
            for attachment in attachments where !represented.contains(attachment.id) {
                markIncomplete(attachment, reason: "it has no inline marker in the note HTML")
            }
        }

        return processedHTML
    }

    /// Replace <object> tags with actual attachment content
    private func replaceObjectTags(
        in html: String,
        attachmentMap: [String: NotesAttachment],
        attachmentPaths: [String: String],
        embedImages: Bool,
        linkEmbeddedImages: Bool,
        standalonePDF: Bool
    ) -> String {
        var result = html

        // Pattern to match <span data-attachment-id="..." data-attachment-type="...">...</span>
        let spanPattern = #"<span\s+data-attachment-id="([^"]+)"\s+data-attachment-type="([^"]+)">.*?</span>"#

        guard let regex = try? NSRegularExpression(pattern: spanPattern, options: [.dotMatchesLineSeparators]) else {
            Logger.noteQuery.error("Failed to create span tag regex")
            return html
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        // Process matches in reverse to maintain string indices
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }

            let fullRange = match.range(at: 0)
            let uuidRange = match.range(at: 1)
            let typeRange = match.range(at: 2)

            let uuid = nsString.substring(with: uuidRange)
            let typeUti = nsString.substring(with: typeRange)

            let replacement: String
            if let attachment = attachmentMap[uuid] {
                replacement = generateReplacementHTML(
                    for: attachment,
                    uuid: uuid,
                    relativePath: attachmentPaths[uuid],
                    embedImages: embedImages,
                    linkEmbeddedImages: linkEmbeddedImages,
                    standalonePDF: standalonePDF
                )
            } else if standalonePDF {
                let unverified = NotesAttachment(id: uuid, typeUTI: typeUti, filename: nil)
                markIncomplete(unverified, reason: "ownership validation did not include this attachment; original content was not accessed")
                replacement = Self.standaloneFileReferenceHTML(
                    filename: "Unverified attachment \(uuid)",
                    description: "Ownership could not be verified; original content was not accessed"
                )
            } else {
                let attachment = NotesAttachment(id: uuid, typeUTI: typeUti, filename: nil)
                replacement = generateReplacementHTML(
                    for: attachment,
                    uuid: uuid,
                    relativePath: attachmentPaths[uuid],
                    embedImages: embedImages,
                    linkEmbeddedImages: linkEmbeddedImages,
                    standalonePDF: false
                )
            }

            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }

        return result
    }

    /// Generate replacement HTML for an attachment
    private func generateReplacementHTML(
        for attachment: NotesAttachment,
        uuid: String,
        relativePath: String?,
        embedImages: Bool,
        linkEmbeddedImages: Bool,
        standalonePDF: Bool
    ) -> String {
        // A Notes gallery is a collection, not one raster image. The current
        // single-PDF path cannot render every child image in its original order,
        // so show an explicit incomplete reference rather than silently using
        // only the first staged child as if it represented the whole gallery.
        if standalonePDF && attachment.typeUTI == "com.apple.notes.gallery" {
            markIncomplete(attachment, reason: "the gallery’s original images are not all rendered in the standalone PDF")
            return Self.standaloneFileReferenceHTML(
                filename: attachment.filename ?? "Image gallery",
                description: "Original gallery images not fully rendered or embedded"
            )
        }

        // Check if this is an image
        // Also treat drawings/sketches as images since they have fallback image data
        if Self.isInlineImageType(attachment.typeUTI) {
            return generateImageHTML(
                attachment: attachment,
                uuid: uuid,
                relativePath: relativePath,
                embedInline: embedImages,
                wrapInLink: linkEmbeddedImages,
                standalonePDF: standalonePDF
            )
        }

        // Check if this is a table
        if attachment.typeUTI == "com.apple.notes.table" {
            let tableHTML = generateTableHTML(uuid: uuid)
            if standalonePDF, tableHTML == "[Table could not be rendered]" {
                markIncomplete(attachment, reason: "the Notes table could not be rendered")
            }
            return tableHTML
        }

        // Check if this is a URL link card
        if attachment.typeUTI == "public.url" {
            return generateURLCardHTML(uuid: uuid, attachment: attachment, standalonePDF: standalonePDF)
        }

        // Check if this is a PDF
        if attachment.typeUTI == "com.adobe.pdf" || attachment.typeUTI == "public.pdf" {
            if standalonePDF {
                markIncomplete(attachment, reason: "the original PDF file is not embedded")
                return Self.standaloneFileReferenceHTML(
                    filename: attachment.filename ?? "PDF document",
                    description: "Original PDF file not embedded in this PDF"
                )
            }
            return generatePDFLinkHTML(attachment: attachment, relativePath: relativePath)
        }

        if standalonePDF {
            markIncomplete(attachment, reason: "the original file is not embedded")
            return Self.standaloneFileReferenceHTML(
                filename: attachment.filename ?? attachment.name,
                description: "Original file not embedded in this PDF (\(getTypeDescription(for: attachment.typeUTI)))"
            )
        }

        // For other attachments, generate a styled link
        if let path = relativePath {
            // Extract filename from the relative path if attachment.filename is not available
            let filename = attachment.filename ?? (path as NSString).lastPathComponent
            return generateGenericAttachmentHTML(filename: filename, path: path, typeUTI: attachment.typeUTI)
        }

        // Fallback: return placeholder
        return "[Attachment: \(attachment.typeUTI)]"
    }

    /// Generate HTML for image attachments
    private func generateImageHTML(
        attachment: NotesAttachment,
        uuid: String,
        relativePath: String?,
        embedInline: Bool,
        wrapInLink: Bool,
        standalonePDF: Bool
    ) -> String {
        let altText = (attachment.filename ?? "image").htmlEscaped
        let safePath = relativePath?.htmlEscaped

        // Prefer the database's original bytes, then an exported staging file.
        // For standalone PDFs the data URI is the only acceptable image source:
        // a link into the staging folder would break as soon as export returns.
        if let imageData = getImageData(uuid: uuid, relativePath: relativePath) {
            let base64: String
            let mimeType: String
            if standalonePDF {
                guard let (renderableData, detectedMimeType) = renderableImageData(
                    imageData, typeUTI: attachment.typeUTI
                ) else {
                    markIncomplete(attachment, reason: "image bytes were unavailable or could not be decoded")
                    return "<span style=\"color:#8b1e1e;\">[Image unavailable: \(altText)]</span>"
                }
                base64 = renderableData.base64EncodedString()
                mimeType = detectedMimeType
            } else {
                // Keep the established CLI/MCP/backup HTML behavior exactly:
                // standalone PDFs use byte-detected, renderable data URIs,
                // while existing export surfaces retain their UTI mapping.
                base64 = legacyImageBase64(imageData, typeUTI: attachment.typeUTI)
                mimeType = utiToMimeType(attachment.typeUTI)
            }
            let imgTag = "<img src=\"data:\(mimeType);base64,\(base64)\" alt=\"\(altText)\" />"

            // If embedInline is false but we have a relativePath, use the path instead
            if !embedInline, let path = safePath {
                return "<img src=\"\(path)\" alt=\"\(altText)\" />"
            }

            // Optionally wrap embedded image in link to file
            if embedInline && wrapInLink, let path = safePath {
                return "<a href=\"\(path)\">\(imgTag)</a>"
            }

            return imgTag
        }

        if standalonePDF {
            markIncomplete(attachment, reason: "image bytes were unavailable or could not be decoded")
            return "<span style=\"color:#8b1e1e;\">[Image unavailable: \(altText)]</span>"
        }

        // Fall back to linking to the file if base64 failed
        if let path = safePath {
            return "<img src=\"\(path)\" alt=\"\(altText)\" />"
        }

        // Last resort: show placeholder
        Logger.noteQuery.warning("Could not embed or link to image \(uuid) - no base64 data or file path available")
        return "[Image: \((attachment.filename ?? uuid).htmlEscaped)]"
    }

    /// Generate HTML for table attachments by parsing protobuf
    private func generateTableHTML(uuid: String) -> String {
        Logger.noteQuery.info("Processing table attachment with UUID: \(uuid)")

        if let parsedTable = tableParser.parseTable(uuid: uuid) {
            Logger.noteQuery.info("Successfully rendered table \(uuid) with \(parsedTable.rowCount) rows and \(parsedTable.columnCount) columns")
            return parsedTable.toHTML()
        }

        Logger.noteQuery.warning("Failed to render table \(uuid) - TableParser.parseTable() returned nil")
        return "[Table could not be rendered]"
    }

    /// Generate HTML for URL link card attachments
    private func generateURLCardHTML(
        uuid: String,
        attachment: NotesAttachment,
        standalonePDF: Bool
    ) -> String {
        Logger.noteQuery.debug("Processing URL link card with UUID: \(uuid)")

        // Try to fetch URL and title from database
        if let (url, title) = fetchURLLinkCard(uuid: uuid) {
            guard !standalonePDF || isSafeExternalURL(url) else {
                markIncomplete(attachment, reason: "the link card does not contain a safe HTTP or HTTPS URL")
                return "[Link unavailable: \((attachment.filename ?? url).htmlEscaped)]"
            }
            Logger.noteQuery.debug("Successfully fetched URL link card: url=\(url), title=\(title ?? "nil")")
            if standalonePDF {
                notices.append("Link card '\(attachment.filename ?? title ?? url)' remains an external web link; the linked page is not downloaded or embedded.")
            }
            let displayTitle = title ?? url
            return """
            <div style="border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin: 8px 0; background: #f9f9f9; display: flex; align-items: center; font-size: 14px; font-weight: normal; font-style: normal; text-decoration: none;">
                <div style="font-size: 24px; margin-right: 12px; line-height: 1;">🔗</div>
                <div style="flex: 1; min-width: 0;">
                    <a href="\(url.htmlEscaped)" target="_blank" style="text-decoration: none; color: #007AFF; font-weight: 500; display: block; font-size: 14px; overflow-wrap: break-word; word-break: break-all;">\(displayTitle.htmlEscaped)</a>
                    <div style="font-size: 12px; color: #666; margin-top: 4px; font-weight: normal; overflow-wrap: break-word; word-break: break-all;">\(url.htmlEscaped)</div>
                </div>
            </div>
            """
        }

        Logger.noteQuery.warning("Could not fetch URL data for link card \(uuid)")
        if standalonePDF {
            markIncomplete(attachment, reason: "the link card URL could not be read")
        }
        return "<div style=\"color: #999; font-style: italic;\">[URL Link Card]</div>"
    }

    /// Generate HTML for PDF attachments
    private func generatePDFLinkHTML(attachment: NotesAttachment, relativePath: String?) -> String {
        guard let path = relativePath else {
            return "[PDF: \(attachment.filename ?? "document")]"
        }

        // Extract filename from the relative path if attachment.filename is not available
        let filename = attachment.filename ?? (path as NSString).lastPathComponent
        return """
        <div style="border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin: 8px 0; background: #fff5f5; display: flex; align-items: center; font-size: 14px; font-weight: normal; font-style: normal; text-decoration: none;">
            <div style="font-size: 24px; margin-right: 12px; line-height: 1;">📄</div>
            <div style="flex: 1;">
                <a href="\(path.htmlEscaped)" target="_blank" style="text-decoration: none; color: #d32f2f; font-weight: 500; display: block; font-size: 14px;">\(filename.htmlEscaped)</a>
                <div style="font-size: 12px; color: #666; margin-top: 4px; font-weight: normal;">PDF Document</div>
            </div>
        </div>
        """
    }

    /// Generate HTML for generic file attachments
    private func generateGenericAttachmentHTML(filename: String, path: String, typeUTI: String) -> String {
        let icon = getFileIcon(for: typeUTI)
        let typeDescription = getTypeDescription(for: typeUTI)

        return """
        <div style="border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin: 8px 0; background: #f9f9f9; display: flex; align-items: center; font-size: 14px; font-weight: normal; font-style: normal; text-decoration: none;">
            <div style="font-size: 24px; margin-right: 12px; line-height: 1;">\(icon)</div>
            <div style="flex: 1;">
                <a href="\(path.htmlEscaped)" target="_blank" style="text-decoration: none; color: #333; font-weight: 500; display: block; font-size: 14px;">\(filename.htmlEscaped)</a>
                <div style="font-size: 12px; color: #666; margin-top: 4px; font-weight: normal;">\(typeDescription)</div>
            </div>
        </div>
        """
    }

    private static func standaloneFileReferenceHTML(filename: String, description: String) -> String {
        """
        <div style="border: 1px solid #d8d8d8; border-radius: 6px; padding: 10px; margin: 8px 0; color: #333;">
            <strong>📎 \(filename.htmlEscaped)</strong>
            <div style="font-size: 12px; color: #666; margin-top: 4px;">\(description.htmlEscaped). Only a reference is shown; the original file is not embedded.</div>
        </div>
        """
    }

    private func markIncomplete(_ attachment: NotesAttachment, reason: String) {
        incompleteAttachmentIDs.insert(attachment.id)
        let label = attachment.filename ?? attachment.id
        diagnostics.append("Attachment '\(label)' (\(attachment.typeUTI)) is incomplete in the standalone PDF: \(reason).")
    }

    private func representedAttachmentIDs(in html: String) -> Set<String> {
        let pattern = #"<span\s+data-attachment-id="([^"]+)"\s+data-attachment-type="[^"]+">.*?</span>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsHTML = html as NSString
        return Set(regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsHTML.substring(with: match.range(at: 1))
        })
    }

    private func isSafeExternalURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return false }
        return true
    }

    /// Get an appropriate emoji icon for a file type
    private func getFileIcon(for typeUTI: String) -> String {
        if typeUTI.contains("video") || typeUTI.contains("movie") || typeUTI.contains("mp4") || typeUTI.contains("mov") {
            return "🎬"
        } else if typeUTI.contains("audio") || typeUTI.contains("music") || typeUTI.contains("mp3") {
            return "🎵"
        } else if typeUTI.contains("zip") || typeUTI.contains("archive") {
            return "📦"
        } else if typeUTI.contains("text") || typeUTI.contains("txt") {
            return "📝"
        } else {
            return "📎"
        }
    }

    /// Get a user-friendly description for a file type
    private func getTypeDescription(for typeUTI: String) -> String {
        let descriptions: [String: String] = [
            "public.movie": "Video",
            "com.apple.quicktime-movie": "QuickTime Movie",
            "public.mpeg-4": "MP4 Video",
            "public.mp3": "MP3 Audio",
            "public.text": "Text File",
            "public.plain-text": "Plain Text",
            "public.zip-archive": "ZIP Archive",
            "org.openxmlformats.wordprocessingml.document": "Word Document",
            "com.microsoft.word.doc": "Microsoft Word Document",
            "com.microsoft.word.docx": "Microsoft Word Document",
            "net.daringfireball.markdown": "Markdown Document",
            "public.markdown": "Markdown Document"
        ]

        if let description = descriptions[typeUTI] {
            return description
        }

        // Extract last component of UTI as fallback
        let components = typeUTI.components(separatedBy: ".")
        if let last = components.last {
            return last.capitalized + " File"
        }

        return "File"
    }

    /// Fetch URL link card data from database
    private func fetchURLLinkCard(uuid: String) -> (url: String, title: String?)? {
        let query = """
        SELECT ZURLSTRING, ZTITLE, ZALTTEXT
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare URL link card query for UUID \(uuid)")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (uuid as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No data found in database for URL link card UUID \(uuid)")
            return nil
        }

        // Get the URL from ZURLSTRING column
        guard let urlString = sqlite3_column_text(statement, 0).flatMap({ String(cString: $0) }) else {
            Logger.noteQuery.warning("URL link card \(uuid): ZURLSTRING is NULL")
            return nil
        }

        // Try to get title from ZTITLE or ZALTTEXT columns
        let title = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) }
            ?? sqlite3_column_text(statement, 2).flatMap { String(cString: $0) }

        Logger.noteQuery.debug("URL link card \(uuid): url=\(urlString), title=\(title ?? "nil")")

        return (url: urlString, title: title)
    }

    /// Extract URL from mergeable data protobuf
    private func extractURLFromMergeableData(_ data: Data) -> String? {
        // Decompress if gzipped
        if let decompressed = data.gunzipped() {
            return extractURLFromProtobuf(decompressed)
        }

        // Try parsing directly if not gzipped
        return extractURLFromProtobuf(data)
    }

    /// Extract URL string from protobuf data
    private func extractURLFromProtobuf(_ data: Data) -> String? {
        do {
            let proto = try MergableDataProto(serializedBytes: data, extensions: nil, partial: true)
            let objectData = proto.mergableDataObject.mergeableDataObjectData

            Logger.noteQuery.debug("URL protobuf has \(objectData.mergeableDataObjectEntry.count) entries")

            // Look for URL in the note text or string values
            for (index, entry) in objectData.mergeableDataObjectEntry.enumerated() {
                if entry.hasNote {
                    let text = entry.note.noteText
                    Logger.noteQuery.debug("Entry[\(index)] has Note with text: '\(text)'")
                    // Check if it looks like a URL
                    if text.hasPrefix("http://") || text.hasPrefix("https://") {
                        Logger.noteQuery.debug("Found URL in entry[\(index)]: \(text)")
                        return text
                    }
                }
            }

            Logger.noteQuery.debug("No URL found in any Note entries")
        } catch {
            Logger.noteQuery.warning("Failed to parse URL protobuf: \(error.localizedDescription)")
        }

        return nil
    }

    /// Get base64-encoded image data from database or exported file
    private func getImageData(uuid: String, relativePath: String?) -> Data? {
        // Query for the media blob
        let query = """
        SELECT ZMEDIA
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare image query for UUID \(uuid)")
            return tryLoadImageDataFromFile(relativePath: relativePath, uuid: uuid)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (uuid as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No media data found in ZMEDIA for UUID \(uuid), trying external file")
            return tryLoadImageDataFromFile(relativePath: relativePath, uuid: uuid)
        }

        // Get the blob data
        if let blob = sqlite3_column_blob(statement, 0) {
            let size = sqlite3_column_bytes(statement, 0)

            // If size is very small (< 100 bytes), it's likely just a reference, not actual image data
            let data = Data(bytes: blob, count: Int(size))
            if size < 100 && imageMimeType(from: data) == nil {
                Logger.noteQuery.debug("ZMEDIA has only \(size) non-image bytes for UUID \(uuid) - likely a reference, trying external file")
                return tryLoadImageDataFromFile(relativePath: relativePath, uuid: uuid)
            }

            Logger.noteQuery.debug("Successfully retrieved \(size) bytes of image data from ZMEDIA for UUID \(uuid)")

            return data
        }

        Logger.noteQuery.warning("ZMEDIA column was NULL for UUID \(uuid), trying external file")
        return tryLoadImageDataFromFile(relativePath: relativePath, uuid: uuid)
    }

    /// Try to load image bytes from the exported file
    private func tryLoadImageDataFromFile(relativePath: String?, uuid: String) -> Data? {
        guard let relativePath = relativePath, let exportDir = exportDirectory else {
            Logger.noteQuery.debug("Cannot load from file - no relativePath or exportDirectory for UUID \(uuid)")
            return nil
        }

        // Combine export directory with relative path
        let fullPath = (exportDir as NSString).appendingPathComponent(relativePath)

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
            Logger.noteQuery.debug("Successfully loaded \(data.count) bytes from external file for UUID \(uuid)")

            return data
        } catch {
            Logger.noteQuery.warning("Failed to load image from file \(fullPath): \(error.localizedDescription)")
            return nil
        }
    }

    /// Convert HEIC image data to JPEG to avoid WebKit rendering issues
    /// Returns nil if conversion fails
    private func convertHEICToJPEG(_ heicData: Data) -> Data? {
        guard let image = NSImage(data: heicData) else {
            Logger.noteQuery.error("Failed to create NSImage from HEIC data")
            return nil
        }

        guard let tiffData = image.tiffRepresentation else {
            Logger.noteQuery.error("Failed to get TIFF representation from NSImage")
            return nil
        }

        guard let bitmap = NSBitmapImageRep(data: tiffData) else {
            Logger.noteQuery.error("Failed to create bitmap from TIFF data")
            return nil
        }

        // Convert to JPEG with quality 0.9 (good balance between quality and size)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            Logger.noteQuery.error("Failed to convert bitmap to JPEG")
            return nil
        }

        return jpegData
    }

    /// Returns bytes and a MIME type that the HTML renderer can actually load.
    /// MIME is identified from the bytes rather than guessed from a broad UTI.
    private func renderableImageData(_ data: Data, typeUTI: String) -> (Data, String)? {
        let isHEIC = typeUTI.localizedCaseInsensitiveContains("heic")
            || typeUTI.localizedCaseInsensitiveContains("heif")
            || imageMimeType(from: data) == "image/heic"
        if isHEIC {
            if let jpeg = convertHEICToJPEG(data), imageMimeType(from: jpeg) == "image/jpeg" {
                return (jpeg, "image/jpeg")
            }
            return nil
        }

        if let mimeType = imageMimeType(from: data) {
            guard mimeType != "image/avif" else { return nil }
            return (data, mimeType)
        }

        // Apple drawing/scanned-image payloads are not always stored as a
        // standard raster file. Decode with AppKit and normalize only if it
        // succeeds; otherwise report a missing image rather than inventing PNG.
        if let image = NSImage(data: data),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }

        return nil
    }

    private func legacyImageBase64(_ data: Data, typeUTI: String) -> String {
        if typeUTI.localizedCaseInsensitiveContains("heic") || typeUTI.localizedCaseInsensitiveContains("heif") {
            if let convertedData = convertHEICToJPEG(data) {
                return convertedData.base64EncodedString()
            }
            Logger.noteQuery.warning("Failed to convert HEIC image, using original bytes for legacy HTML")
        }
        return data.base64EncodedString()
    }

    private func imageMimeType(from data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if bytes.count >= 12,
           String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "image/heic" }
            if brand == "avif" || brand == "avis" { return "image/avif" }
        }
        return nil
    }

    /// Convert UTI to MIME type
    private func utiToMimeType(_ uti: String) -> String {
        let mimeTypes: [String: String] = [
            "public.jpeg": "image/jpeg",
            "public.png": "image/png",
            "public.heic": "image/jpeg",  // Return JPEG MIME type for HEIC since we convert it
            "public.image": "image/png",
            "public.tiff": "image/tiff",
            "com.compuserve.gif": "image/gif"
        ]

        return mimeTypes[uti] ?? "image/png"
    }
}
