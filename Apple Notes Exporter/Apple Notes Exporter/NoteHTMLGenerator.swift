//
//  NoteHTMLGenerator.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  The approach for walking AttributeRun / ParagraphStyle protobuf fields
//  to produce HTML mirrors the generate_html logic in AppleNote.rb from
//  threeplanetssoftware's apple_cloud_notes_parser
//  (https://github.com/threeplanetssoftware/apple_cloud_notes_parser),
//  licensed under the MIT License. See Licenses/threeplanetssoftware-LICENSE.txt.
//  Independently reimplemented in Swift. Modifications (C) 2026 Konstantin
//  Zaremski, licensed under GPLv3.
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
import OSLog

// MARK: - Note Attachment Model

/// Lightweight attachment descriptor extracted from protobuf data
struct NoteAttachment {
    let id: String
    let typeUTI: String
    let filepath: String?
}

// MARK: - Note HTML Generator

/// Generates HTML from protobuf Note objects and handles inline attachment queries.
/// Extracted from AppleNotesDatabaseParser to work with the C parser backend.
class NoteHTMLGenerator {
    private let db: OpaquePointer?  // ane_db handle for C API calls

    init(database: OpaquePointer?) {
        self.db = database
    }

    // MARK: - Public API

    /// Generate HTML for a note from its raw gzipped protobuf data.
    /// Returns nil if decompression or protobuf parsing fails.
    func generateHTML(fromProtobufData data: Data) -> String? {
        guard let decompressed = data.gunzipped() else {
            Logger.noteQuery.error("Failed to decompress gzip data")
            return nil
        }

        do {
            let proto = try NoteStoreProto(serializedBytes: decompressed)
            guard proto.hasDocument, proto.document.hasNote else {
                Logger.noteQuery.error("Protobuf has no document/note")
                return nil
            }
            return generateHTML(from: proto.document.note)
        } catch {
            Logger.noteQuery.error("Failed to parse protobuf: \(error)")
            return nil
        }
    }

    /// Extract plaintext from gzipped protobuf data.
    func extractPlaintext(fromProtobufData data: Data) -> String? {
        guard let decompressed = data.gunzipped() else { return nil }

        do {
            let proto = try NoteStoreProto(serializedBytes: decompressed)
            guard proto.hasDocument, proto.document.hasNote else { return nil }
            return proto.document.note.noteText
        } catch {
            return nil
        }
    }

    /// Extract attachment info from gzipped protobuf data.
    func extractAttachments(fromProtobufData data: Data) -> [NoteAttachment] {
        guard let decompressed = data.gunzipped() else { return [] }

        do {
            let proto = try NoteStoreProto(serializedBytes: decompressed)
            guard proto.hasDocument, proto.document.hasNote else { return [] }
            return extractAttachments(from: proto.document.note)
        } catch {
            return []
        }
    }

    // MARK: - HTML Generation (from protobuf Note)

    /// Generates HTML from a protobuf Note
    // Kept internal so formatting can be exercised with synthetic protobuf
    // messages without creating or reading a real Notes database.
    func generateHTML(from note: Note) -> String {
        var html = "<html><body>"

        let text = note.noteText
        var currentPos = 0

        // Condense consecutive attribute runs with the same style
        var condensedRuns: [AttributeRun] = []
        var i = 0
        while i < note.attributeRun.count {
            let currentRun = note.attributeRun[i]
            var combinedLength = currentRun.length

            while i + 1 < note.attributeRun.count && isSameStyle(currentRun, note.attributeRun[i + 1]) {
                i += 1
                combinedLength += note.attributeRun[i].length
            }

            if combinedLength != currentRun.length {
                var mergedRun = currentRun
                mergedRun.clearLength()
                mergedRun.length = combinedLength
                condensedRuns.append(mergedRun)
            } else {
                condensedRuns.append(currentRun)
            }

            i += 1
        }

        // Track list state with nesting support
        var listStack: [(type: Int32, indentLevel: Int32)] = []
        var currentListItemHTML = ""
        var inListItem = false

        for (_, run) in condensedRuns.enumerated() {
            let length = Int(run.length)
            let utf16View = text.utf16
            let endPos = min(currentPos + length, utf16View.count)

            guard let startIndex = utf16View.index(utf16View.startIndex, offsetBy: currentPos, limitedBy: utf16View.endIndex),
                  let endIndex = utf16View.index(utf16View.startIndex, offsetBy: endPos, limitedBy: utf16View.endIndex) else {
                currentPos = endPos
                continue
            }

            let utf16Slice = utf16View[startIndex..<endIndex]
            let segment = String(utf16Slice) ?? ""

            // Determine list item properties
            var isListItem = false
            var listStyleType = ""
            var listTagName = ""
            var checkboxPrefix = ""
            var indentLevel: Int32 = 0
            var listType: Int32 = 0

            if run.hasParagraphStyle {
                let style = run.paragraphStyle
                indentLevel = style.indentAmount

                switch style.styleType {
                case 100: // Dotted list
                    isListItem = true
                    listStyleType = "disc"
                    listTagName = "ul"
                    listType = 100
                case 101: // Dashed list
                    isListItem = true
                    listStyleType = "square"
                    listTagName = "ul"
                    listType = 101
                case 102: // Numbered list
                    isListItem = true
                    listStyleType = "decimal"
                    listTagName = "ol"
                    listType = 102
                case 103: // Checkbox
                    isListItem = true
                    listStyleType = "none"
                    listTagName = "ul"
                    listType = 103
                    let checked = style.hasChecklist && style.checklist.done != 0
                    checkboxPrefix = checked ? "☑ " : "☐ "
                default:
                    break
                }
            }

            // Handle list nesting
            if isListItem {
                while !listStack.isEmpty && listStack.last!.indentLevel >= indentLevel &&
                      (listStack.last!.indentLevel > indentLevel || listStack.last!.type != listType) {
                    let closed = listStack.removeLast()
                    html += (closed.type == 102) ? "</ol>" : "</ul>"
                }

                while listStack.isEmpty || listStack.last!.indentLevel < indentLevel {
                    let newIndent = listStack.isEmpty ? 0 : listStack.last!.indentLevel + 1
                    if newIndent > indentLevel { break }

                    if listTagName == "ol" {
                        html += "<ol>"
                    } else {
                        if listStyleType == "square" {
                            html += "<ul style='list-style-type: square;'>"
                        } else if listStyleType == "none" {
                            html += "<ul style='list-style-type: none;'>"
                        } else {
                            html += "<ul>"
                        }
                    }
                    listStack.append((type: listType, indentLevel: newIndent))
                }
            } else {
                while !listStack.isEmpty {
                    let closed = listStack.removeLast()
                    html += (closed.type == 102) ? "</ol>" : "</ul>"
                }
            }

            // Handle list items
            if isListItem {
                // segment is raw plaintext from the note; escape it unless we're
                // about to replace it with attachment HTML below.
                var styledText = run.hasAttachmentInfo ? segment : segment.htmlEscaped
                let tags = formattingTags(for: run)

                if run.hasAttachmentInfo {
                    styledText = processAttachmentRun(run: run)
                }

                let parts = styledText.components(separatedBy: "\n")
                for (partIndex, part) in parts.enumerated() {
                    let isLastPart = (partIndex == parts.count - 1)
                    if isLastPart && part.isEmpty { continue }

                    if !inListItem {
                        inListItem = true
                        currentListItemHTML = checkboxPrefix
                    }

                    if !part.isEmpty {
                        currentListItemHTML += tags.open + part + tags.close
                    }

                    if !isLastPart {
                        html += "<li>" + currentListItemHTML + "</li>"
                        currentListItemHTML = ""
                        inListItem = false
                    }
                }
            } else {
                // Close pending list item
                if inListItem {
                    let hasContent = currentListItemHTML.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
                    if hasContent { html += "<li>" + currentListItemHTML + "</li>" }
                    currentListItemHTML = ""
                    inListItem = false
                }

                // Non-list content
                let tags = formattingTags(for: run)

                let renderedSegment: String
                if run.hasAttachmentInfo {
                    renderedSegment = processAttachmentRun(run: run)
                } else {
                    renderedSegment = segment.htmlEscaped
                }

                html += tags.open + renderedSegment.replacingOccurrences(of: "\n", with: "<br>") + tags.close
            }

            currentPos = endPos
        }

        // Close pending list items and lists
        if inListItem {
            let hasContent = currentListItemHTML.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
            if hasContent { html += "<li>" + currentListItemHTML + "</li>" }
        }
        while !listStack.isEmpty {
            let closed = listStack.removeLast()
            html += (closed.type == 102) ? "</ol>" : "</ul>"
        }

        html += "</body></html>"
        return html
    }

    // MARK: - Attachment Processing

    /// Process an attachment run into HTML (marker spans or inline text)
    private func processAttachmentRun(run: AttributeRun) -> String {
        let typeUti = run.attachmentInfo.typeUti
        let attachmentId = run.attachmentInfo.attachmentIdentifier
        let safeId = attachmentId.htmlEscaped
        let safeUti = typeUti.htmlEscaped

        // Table marker
        if typeUti == "com.apple.notes.table" {
            return "<span data-attachment-id=\"\(safeId)\" data-attachment-type=\"\(safeUti)\">&#xFFFC;</span>"
        }
        // Image marker
        if typeUti.hasPrefix("public.image") || typeUti.hasPrefix("public.jpeg") ||
           typeUti.hasPrefix("public.png") || typeUti.hasPrefix("public.heic") {
            return "<span data-attachment-id=\"\(safeId)\" data-attachment-type=\"\(safeUti)\">&#xFFFC;</span>"
        }
        // Inline text attachments (hashtags, mentions, links, etc.)
        if typeUti.hasPrefix("com.apple.notes.inlinetextattachment") {
            if let inlineText = getInlineAttachmentText(uuid: attachmentId, typeUti: typeUti) {
                return inlineText
            }
            return ""
        }
        // All other file attachments
        return "<span data-attachment-id=\"\(safeId)\" data-attachment-type=\"\(safeUti)\">[File: \(safeUti)]</span>"
    }

    /// Sanitize a link href to block XSS via javascript:/data:/vbscript: URIs.
    /// Allows http(s), mailto, tel, ftp, sms, and Apple Notes internal links;
    /// everything else is replaced with "#". Also HTML-escapes the allowed URL.
    private func sanitizeLinkHref(_ link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let allowedSchemes = ["http://", "https://", "mailto:", "applenotes:", "tel:", "sms:", "ftp://"]
        if allowedSchemes.contains(where: { lower.hasPrefix($0) }) {
            return trimmed.htmlEscaped
        }
        return "#"
    }

    /// Query inline attachment text using the C parser API
    private func getInlineAttachmentText(uuid: String, typeUti: String) -> String? {
        guard let db = db else { return nil }

        let result = ane_fetch_inline_attachment(db, uuid)
        guard let att = result else { return nil }
        defer { ane_free_inline_attachment(att) }

        guard let altTextPtr = att.pointee.alt_text else { return nil }
        let altText = String(cString: altTextPtr)

        if let tokenPtr = att.pointee.token_identifier {
            let token = String(cString: tokenPtr)

            // A link to another note becomes a real anchor, so that
            // rewriteInternalLinks can retarget the href at the exported file
            // and the result is actually clickable. Emitted as plain text it
            // was only ever a bare applenotes: URL sitting in the output.
            if typeUti == "com.apple.notes.inlinetextattachment.link" {
                return "<a href=\"\(token.htmlEscaped)\">\(altText.htmlEscaped)</a>"
            }

            // Mentions point at people, not notes, so there is nothing to link
            // to. Keep the token visible rather than dropping information.
            if typeUti == "com.apple.notes.inlinetextattachment.mention" {
                return "\(altText) [\(token)]"
            }
        }

        return altText
    }

    // MARK: - Helpers

    /// Build balanced semantic wrappers for the styles carried by a run.
    /// Unknown numeric values are not mapped to invented visual meanings.
    private func formattingTags(for run: AttributeRun) -> (open: String, close: String) {
        var wrappers: [(open: String, close: String)] = []

        if run.hasParagraphStyle {
            let style = run.paragraphStyle
            let alignment = alignmentDeclaration(for: style)

            if style.hasBlockQuote && style.blockQuote != 0 {
                var declarations = ["margin: 4px 0", "padding-left: 12px", "border-left: 3px solid #ccc"]
                if let alignment { declarations.append(alignment) }
                wrappers.append(("<blockquote class=\"ane-blockquote\"\(styleAttribute(declarations))>", "</blockquote>"))
            }

            switch style.styleType {
            case 0: wrappers.append((styledElementOpenTag("h1", alignment: alignment), "</h1>"))
            case 1: wrappers.append((styledElementOpenTag("h2", alignment: alignment), "</h2>"))
            case 2: wrappers.append((styledElementOpenTag("h3", alignment: alignment), "</h3>"))
            case 4:
                let declarations = [
                    "white-space: pre-wrap", "font-family: monospace", "background: #f5f5f5",
                    "padding: 8px", "border-radius: 4px", "margin: 4px 0"
                ] + (alignment.map { [$0] } ?? [])
                wrappers.append(("<pre class=\"ane-monostyle\"\(styleAttribute(declarations))>", "</pre>"))
            default:
                if let alignment {
                    wrappers.append(("<div class=\"ane-aligned-paragraph\"\(styleAttribute([alignment]))>", "</div>"))
                }
            }
        }

        if run.hasFont {
            var declarations: [String] = []
            if run.font.hasFontName, !run.font.fontName.isEmpty {
                declarations.append("font-family: \"\(escapeCSSString(run.font.fontName))\"")
            }
            if run.font.hasPointSize, run.font.pointSize.isFinite, run.font.pointSize > 0 {
                declarations.append("font-size: \(run.font.pointSize)pt")
            }
            if !declarations.isEmpty {
                wrappers.append(("<span\(styleAttribute(declarations))>", "</span>"))
            }
        }

        if run.hasColor {
            wrappers.append(("<span\(styleAttribute([colorDeclaration(for: run.color)]))>", "</span>"))
        }

        if run.hasEmphasisStyle, run.emphasisStyle != 0 {
            let highlightNames: [Int32: String] = [1: "purple", 2: "pink", 3: "orange", 4: "mint", 5: "blue"]
            if let name = highlightNames[run.emphasisStyle] {
                wrappers.append(("<mark class=\"ane-highlight ane-highlight-\(name)\">", "</mark>"))
            } else {
                // Keep an unrecognized value inspectable without asserting what it means.
                wrappers.append(("<span data-ane-emphasis-style=\"\(run.emphasisStyle)\">", "</span>"))
            }
        }

        if run.hasSuperscript, run.superscript > 0 { wrappers.append(("<sup>", "</sup>")) }
        if run.hasSuperscript, run.superscript < 0 { wrappers.append(("<sub>", "</sub>")) }
        if run.fontWeight == 1 || run.fontWeight == 3 { wrappers.append(("<b>", "</b>")) }
        if run.fontWeight == 2 || run.fontWeight == 3 { wrappers.append(("<i>", "</i>")) }
        if run.underlined != 0 { wrappers.append(("<u>", "</u>")) }
        if run.strikethrough != 0 { wrappers.append(("<s>", "</s>")) }
        if !run.link.isEmpty { wrappers.append(("<a href=\"\(sanitizeLinkHref(run.link))\">", "</a>")) }

        return (
            wrappers.map(\.open).joined(),
            wrappers.reversed().map(\.close).joined()
        )
    }

    private func styledElementOpenTag(_ tag: String, alignment: String?) -> String {
        guard let alignment else { return "<\(tag)>" }
        return "<\(tag)\(styleAttribute([alignment]))>"
    }

    /// The current upstream Notes parser documents these serialized alignment values.
    private func alignmentDeclaration(for style: ParagraphStyle) -> String? {
        guard style.hasAlignment else { return nil }
        switch style.alignment {
        case 1: return "text-align: center"
        case 2: return "text-align: right"
        case 3: return "text-align: justify"
        default: return nil
        }
    }

    private func colorDeclaration(for color: Color) -> String {
        func channel(_ value: Float) -> Int {
            guard value.isFinite else { return 0 }
            return Int((max(0, min(1, value)) * 255).rounded())
        }
        let red = channel(color.red)
        let green = channel(color.green)
        let blue = channel(color.blue)
        let alpha = color.alpha.isFinite ? max(0, min(1, color.alpha)) : 1
        if alpha >= 0.999 {
            return "color: rgb(\(red), \(green), \(blue))"
        }
        let alphaText = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(alpha))
        return "color: rgba(\(red), \(green), \(blue), \(alphaText))"
    }

    private func styleAttribute(_ declarations: [String]) -> String {
        guard !declarations.isEmpty else { return "" }
        return " style=\"\((declarations.joined(separator: "; ") + ";").htmlEscaped)\""
    }

    private func escapeCSSString(_ value: String) -> String {
        value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Check if two attribute runs have the same style (for merging)
    private func isSameStyle(_ run1: AttributeRun, _ run2: AttributeRun) -> Bool {
        if run1.hasAttachmentInfo || run2.hasAttachmentInfo { return false }

        // Compare the full protobuf message except for its required length.
        // Generated equality includes nested presence, every known style field,
        // and unknown wire fields, so future attributes cannot be merged away.
        var first = run1
        var second = run2
        first.length = 0
        second.length = 0
        return first == second
    }

    /// Extract attachment info from protobuf Note
    private func extractAttachments(from note: Note) -> [NoteAttachment] {
        var attachments: [NoteAttachment] = []
        for run in note.attributeRun where run.hasAttachmentInfo {
            let info = run.attachmentInfo
            attachments.append(NoteAttachment(
                id: info.attachmentIdentifier,
                typeUTI: info.typeUti,
                filepath: nil
            ))
        }
        return attachments
    }
}
