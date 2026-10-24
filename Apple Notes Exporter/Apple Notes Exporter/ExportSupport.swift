//
//  ExportSupport.swift
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
import CoreGraphics
import OSLog
import Darwin
import UniformTypeIdentifiers

// MARK: - Logger Categories

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.zaremski.AppleNotesExporter"
    static let noteQuery = Logger(subsystem: subsystem, category: "notequery")
    static let noteExport = Logger(subsystem: subsystem, category: "noteexport")
}

// MARK: - Notes database paths and TCC probe

/// Login-user home directory. `NSHomeDirectory()` can point at a container
/// in helper or sandbox contexts, which then fails to match the path TCC uses
/// for Full Disk Access.
func userHomeDirectoryPath() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithFileSystemRepresentation: dir, isDirectory: true, relativeTo: nil)
            .standardizedFileURL.path
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
}

/// Expand tildes and standardize so TCC and sqlite see a canonical absolute path.
func resolvedFilePath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}

/// Absolute path to the live Apple Notes store.
func defaultNotesDatabasePath() -> String {
    resolvedFilePath(
        userHomeDirectoryPath() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    )
}

/// List the Notes group container using an absolute path.
/// That I/O is what registers this process with TCC; `isReadableFile` is not enough,
/// and there is no public API to grant Full Disk Access.
func hasNotesDatabaseAccess(at databasePath: String = defaultNotesDatabasePath()) -> Bool {
    let absoluteDB = resolvedFilePath(databasePath)
    let container = URL(fileURLWithPath: absoluteDB).deletingLastPathComponent().path
    do {
        _ = try FileManager.default.contentsOfDirectory(atPath: container)
        return true
    } catch {
        return false
    }
}

// MARK: - String Extensions for Escaping

extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Decode common HTML entities to their character equivalents
    var htmlDecoded: String {
        var result = self
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")

        // Decode numeric HTML entities (&#NNN; and &#xHHH;)
        // Decimal entities
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            // Process in reverse to preserve string indices
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let replacement = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        // Hex entities
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let replacement = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        return result
    }

    var rtfEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    var texEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "~", with: "\\textasciitilde{}")
            .replacingOccurrences(of: "^", with: "\\textasciicircum{}")
    }
}

// MARK: - Sync Manifest Actor

/// Thread-safe wrapper for SyncManifest mutations during concurrent export
actor SyncManifestTracker {
    private var manifest: SyncManifest
    private var currentAdded: [SyncManifest.HistoryItem] = []
    private var currentUpdated: [SyncManifest.HistoryItem] = []

    init(manifest: SyncManifest) {
        self.manifest = manifest
    }

    func recordExport(noteId: String, modificationDate: Date, exportedPath: String, attachmentPaths: [String] = []) {
        let item = SyncManifest.HistoryItem(noteId: noteId, path: exportedPath)
        if manifest.notes[noteId] != nil {
            currentUpdated.append(item)
        } else {
            currentAdded.append(item)
        }
        manifest.recordExport(noteId: noteId, modificationDate: modificationDate, exportedPath: exportedPath, attachmentPaths: attachmentPaths)
    }

    func pruneDeleted(presentNoteIds: Set<String>) -> [SyncManifest.PrunedNote] {
        manifest.pruneDeleted(presentNoteIds: presentNoteIds)
    }

    /// Close out this incremental run with a file/folder-level diff.
    func finishRun(pruned: [SyncManifest.PrunedNote]) {
        let deleted = pruned.map { SyncManifest.HistoryItem(noteId: $0.noteId, path: $0.entry.exportedPath) }
        manifest.appendRun(SyncManifest.SyncRun(
            timestamp: Date(),
            added: currentAdded,
            updated: currentUpdated,
            deleted: deleted
        ))
        currentAdded = []
        currentUpdated = []
    }

    func getManifest() -> SyncManifest {
        return manifest
    }
}

// MARK: - Shared Deletion Helper

/// Delete a previously-exported note file and its attachment files.
/// Also deletes any resulting empty `(Attachments)` or ancestor folders up to (but not including) the output root.
func deleteExportedNoteFiles(
    outputRoot: URL,
    entry: SyncManifest.SyncedNoteEntry
) {
    let fm = FileManager.default

    // Collect all files to delete: the note plus its attachments
    var allPaths: [String] = [entry.exportedPath]
    allPaths.append(contentsOf: entry.attachmentPaths)

    // Track parent directories for cleanup pass
    var touchedDirs: Set<URL> = []

    for relPath in allPaths {
        let fileURL = outputRoot.appendingPathComponent(relPath)
        try? fm.removeItem(at: fileURL)
        touchedDirs.insert(fileURL.deletingLastPathComponent())
    }

    // Bottom-up cleanup: remove now-empty folders (Attachments, then account/folder hierarchy),
    // stopping at outputRoot.
    let rootPath = outputRoot.standardizedFileURL.path
    // Sort by depth descending so children are processed before parents.
    let sortedDirs = touchedDirs.sorted { $0.path.count > $1.path.count }
    var dirsToCheck = Set(sortedDirs)
    for dir in sortedDirs {
        var current = dir.standardizedFileURL
        while current.path.count > rootPath.count && current.path.hasPrefix(rootPath) {
            let contents = (try? fm.contentsOfDirectory(atPath: current.path)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: current)
                dirsToCheck.insert(current.deletingLastPathComponent())
            } else {
                break
            }
            current = current.deletingLastPathComponent()
        }
    }
}

// MARK: - Export Progress Tracker Actor

actor ExportProgressTracker {
    private var completedCount: Int = 0
    private var failedNotesCount: Int = 0
    private var failedAttachmentsCount: Int = 0

    func noteCompleted() -> Int {
        completedCount += 1
        return completedCount
    }

    func noteFailed() {
        failedNotesCount += 1
    }

    func attachmentFailed() {
        failedAttachmentsCount += 1
    }

    func getStats() -> (completed: Int, failedNotes: Int, failedAttachments: Int) {
        return (completedCount, failedNotesCount, failedAttachmentsCount)
    }
}

// MARK: - Internal Link Rewriting

/// Pre-allocate a unique filename for each note, honoring the sync manifest's existing paths.
/// Returns `[note.id: <relative path from output root, including extension>]`.
///
/// Output filenames match what exportNote will produce later, so we can rewrite
/// applenotes:note/UUID links to real file paths before the notes are rendered.
func buildInternalLinkPathMap(
    allNotes: [NotesNote],
    notesWithPaths: [(note: NotesNote, folderURL: URL)],
    outputRoot: URL,
    format: ExportFormat,
    addDatePrefix: Bool,
    dateFormat: String,
    existingManifest: SyncManifest?
) -> [String: String] {
    var map: [String: String] = [:]

    // Start with any paths already recorded from previous sync runs.
    if let manifest = existingManifest {
        for (id, entry) in manifest.notes {
            map[id] = entry.exportedPath
        }
    }

    // Pre-allocate filenames for notes being exported this run.
    var reservedByFolder: [String: Set<String>] = [:]
    let rootPath = outputRoot.standardizedFileURL.path

    for pair in notesWithPaths {
        let note = pair.note
        let folderURL = pair.folderURL

        let baseName: String
        if addDatePrefix {
            let formatter = DateFormatter()
            formatter.dateFormat = dateFormat
            baseName = "\(formatter.string(from: note.creationDate)) \(note.sanitizedFileName)"
        } else {
            baseName = note.sanitizedFileName
        }

        let folderKey = folderURL.standardizedFileURL.path
        var used = reservedByFolder[folderKey] ?? []
        // HTML exports write index.html as a folder listing; never let a note claim that name.
        if format == .html {
            used.insert("index.html")
        }

        var filename = "\(baseName).\(format.fileExtension)"
        var counter = 2
        while used.contains(filename) && counter <= 10000 {
            filename = "\(baseName) (\(counter)).\(format.fileExtension)"
            counter += 1
        }
        used.insert(filename)
        reservedByFolder[folderKey] = used

        let fullPath = folderURL.appendingPathComponent(filename).standardizedFileURL.path
        let rel: String
        if fullPath.hasPrefix(rootPath + "/") {
            rel = String(fullPath.dropFirst(rootPath.count + 1))
        } else if fullPath == rootPath {
            rel = filename
        } else {
            rel = folderURL.appendingPathComponent(filename).path
        }
        // Links in note bodies use ZIDENTIFIER (UUID), not the Core Data PK.
        map[note.id] = rel
        if !note.identifier.isEmpty {
            map[note.identifier] = rel
        }
    }

    return map
}

/// Rewrite `applenotes:note/UUID?...` links in HTML to relative paths to the target note's exported file.
/// - currentNoteRelativePath: path of the note whose HTML we are rewriting, relative to the output root.
/// - noteIdToRelativePath: map from note ID to target file path, relative to the output root.
func rewriteInternalLinks(
    html: String,
    currentNoteRelativePath: String,
    noteIdToRelativePath: [String: String]
) -> String {
    guard !noteIdToRelativePath.isEmpty,
          html.contains("applenotes:note/") else { return html }

    // Match applenotes:note/UUID, stopping at the first non-UUID character (?, ", ', >, space, etc.)
    // The query class must exclude ] and ) as well: Apple renders an inline
    // link as "alt [url]", and swallowing the bracket leaves it unbalanced.
    let pattern = #"applenotes:note/([A-Fa-f0-9][A-Fa-f0-9\-]{7,})(\?[^"'<>\s\]\)]*)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

    // Apple stores ZIDENTIFIER uppercase but writes the UUID lowercase into
    // applenotes: links, so a case-sensitive lookup never matches on real
    // data. Normalize here rather than relying on how the caller keyed it.
    var loweredIndex: [String: String] = [:]
    loweredIndex.reserveCapacity(noteIdToRelativePath.count)
    for (key, value) in noteIdToRelativePath {
        let lowered = key.lowercased()
        if loweredIndex[lowered] == nil { loweredIndex[lowered] = value }
    }

    let nsHtml = html as NSString
    let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

    guard !matches.isEmpty else { return html }

    var result = html
    // Process matches in reverse so NSRange offsets stay valid.
    for match in matches.reversed() {
        let fullRange = match.range
        let uuidRange = match.range(at: 1)
        guard uuidRange.location != NSNotFound else { continue }

        let uuid = nsHtml.substring(with: uuidRange)
        guard let targetRelPath = noteIdToRelativePath[uuid]
                ?? loweredIndex[uuid.lowercased()] else { continue }

        let relativeLink = relativePathFromSource(currentNoteRelativePath, toTarget: targetRelPath)
        let encoded = relativeLink.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativeLink

        // Replace the matched substring using Range<String.Index>
        if let range = Range(fullRange, in: result) {
            result.replaceSubrange(range, with: encoded)
        }
    }

    return result
}

/// Compute a relative file path from `source` to `target`, both relative to a common root.
/// Example: source="iCloud/Work/A.md", target="iCloud/Personal/B.md" -> "../Personal/B.md".
func relativePathFromSource(_ source: String, toTarget target: String) -> String {
    let sourceComponents = source.split(separator: "/").map(String.init)
    let targetComponents = target.split(separator: "/").map(String.init)
    guard !sourceComponents.isEmpty else { return target }

    // Source's directory is sourceComponents without the last element (filename).
    let sourceDir = Array(sourceComponents.dropLast())

    // Find common prefix length
    var common = 0
    while common < sourceDir.count && common < targetComponents.count
          && sourceDir[common] == targetComponents[common] {
        common += 1
    }

    var parts: [String] = []
    parts.append(contentsOf: Array(repeating: "..", count: sourceDir.count - common))
    parts.append(contentsOf: targetComponents.dropFirst(common))
    return parts.isEmpty ? targetComponents.last ?? "" : parts.joined(separator: "/")
}

// MARK: - Shared Export Helpers

/// Detect file extension from magic bytes at the start of data.
func detectFileExtension(from data: Data) -> String? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data.prefix(8))

    if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return "jpg" }
    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "png" }
    if bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 { return "pdf" }
    if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 { return "gif" }
    if data.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return "heic" }

    return nil
}

/// Sanitize a string for use as a filename, replacing invalid characters with underscores.
func sanitizeExportFilename(_ name: String) -> String {
    let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.newlines)
        .union(.illegalCharacters)
        .union(.controlCharacters)
    return name.components(separatedBy: invalidCharacters).joined(separator: "_")
}

/// Last-resort name when an account exposes no default folder at all. Only
/// reached on libraries with no ZIDENTIFIER column and no folder named "Notes".
let fallbackNotesFolderName = "Notes"

/// The folder Apple Notes files an account's loose notes into: its default
/// folder. Prefers Apple's "DefaultFolder" ZIDENTIFIER marker so this keeps
/// working on localized libraries where the folder is called "Notizen" or
/// "\u{5907}\u{5FD8}\u{5F55}", and falls back to a root folder literally named
/// "Notes" for older schemas that carry no identifier.
///
/// Candidates are sorted by id so a library with more than one marked folder
/// still resolves to the same folder on every run; export paths and the sync
/// manifest both depend on this being stable.
func defaultNotesFolder(forAccount accountId: String?, in folderLookup: [String: NotesFolder]) -> NotesFolder? {
    guard let accountId, !accountId.isEmpty else { return nil }
    let inAccount = folderLookup.values
        .filter { $0.accountId == accountId }
        .sorted { $0.id < $1.id }

    if let marked = inAccount.first(where: { $0.isDefaultFolder }) {
        return marked
    }
    return inAccount.first { folder in
        folder.name.compare(fallbackNotesFolderName, options: .caseInsensitive) == .orderedSame
            && (folder.parentId == nil || folder.parentId == accountId)
    }
}

/// Join a folder to its ancestors, innermost last. Bounded so a self-parenting
/// or cyclic ZPARENT chain cannot spin forever.
private func folderPath(for folder: NotesFolder, in folderLookup: [String: NotesFolder]) -> String {
    var components: [String] = [sanitizeExportFilename(folder.name)]
    var currentParentId = folder.parentId
    var depth = 0
    while let parentId = currentParentId, let parentFolder = folderLookup[parentId], depth < 64 {
        components.insert(sanitizeExportFilename(parentFolder.name), at: 0)
        currentParentId = parentFolder.parentId
        depth += 1
    }
    return components.joined(separator: "/")
}

/// Build a relative folder path by walking up the parent folder chain.
func buildExportFolderPath(folderId: String, folderLookup: [String: NotesFolder], accountId: String? = nil, isDeleted: Bool = false) -> String {
    if isDeleted {
        return sanitizeExportFilename("Recently Deleted")
    }
    if let folder = folderLookup[folderId] {
        return folderPath(for: folder, in: folderLookup)
    }

    // Unfiled / epoch notes often have a missing or dangling ZFOLDER. Apple
    // Notes shows them in the account's default folder; full and incremental
    // export both do the same rather than inventing an "Unknown Folder".
    if let fallback = defaultNotesFolder(forAccount: accountId, in: folderLookup) {
        return folderPath(for: fallback, in: folderLookup)
    }
    return sanitizeExportFilename(fallbackNotesFolderName)
}

/// Relative directory (account plus folder path) a note belongs in.
func expectedExportDirectory(
    for note: NotesNote,
    accountLookup: [String: String],
    folderLookup: [String: NotesFolder]
) -> String {
    let accountKey = sanitizeExportFilename(accountLookup[note.accountId] ?? "Unknown Account")
    let folderPath = buildExportFolderPath(
        folderId: note.folderId,
        folderLookup: folderLookup,
        accountId: note.accountId,
        isDeleted: note.isDeleted
    )
    return "\(accountKey)/\(folderPath)"
}

/// Drop manifest entries whose files no longer sit where the current resolver
/// would put them, deleting the stale files so the next pass re-exports them in
/// the right place.
///
/// This repairs sync directories written by older versions, which parked
/// unresolvable notes in "Unknown Folder" and then kept overwriting them there
/// forever, and it also picks up notes the user has since moved between folders
/// in Apple Notes. Only the directory is compared: the filename can legitimately
/// differ by a collision suffix such as "Title (2).md".
@discardableResult
func healManifestPaths(
    manifest: inout SyncManifest,
    notes: [NotesNote],
    accountLookup: [String: String],
    folderLookup: [String: NotesFolder],
    outputRoot: URL
) -> [SyncManifest.PrunedNote] {
    var healed: [SyncManifest.PrunedNote] = []
    for note in notes {
        guard let entry = manifest.notes[note.id] else { continue }
        let storedDirectory = (entry.exportedPath as NSString).deletingLastPathComponent
        let expectedDirectory = expectedExportDirectory(
            for: note,
            accountLookup: accountLookup,
            folderLookup: folderLookup
        )
        guard storedDirectory != expectedDirectory else { continue }

        deleteExportedNoteFiles(outputRoot: outputRoot, entry: entry)
        manifest.notes.removeValue(forKey: note.id)
        healed.append(SyncManifest.PrunedNote(noteId: note.id, entry: entry))
    }
    return healed
}

// MARK: - Evernote Limits

/// Evernote's documented ceilings, from Limits.thrift in the EDAM SDK.
enum ENEXLimits {
    /// EDAM_NOTE_CONTENT_LEN_MAX: the ENML content of a single note.
    static let noteContentMax = 5_242_880
    /// EDAM_NOTE_SIZE_MAX_FREE: a whole note including its resources.
    static let noteSizeFreeMax = 26_214_400
    /// EDAM_NOTE_SIZE_MAX_PREMIUM: the same ceiling on a paid plan.
    static let noteSizePaidMax = 209_715_200

    /// A message for a note Evernote may refuse, or nil when it is within the
    /// free-account ceiling. Whether it imports depends on the destination
    /// account, which the exporter cannot know, so this is a warning and not
    /// an error: the file is still written.
    static func oversizeWarning(title: String, byteCount: Int) -> String? {
        guard byteCount > noteSizeFreeMax else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: Int64(noteSizeFreeMax), countStyle: .file)
        let paid = ByteCountFormatter.string(fromByteCount: Int64(noteSizePaidMax), countStyle: .file)
        if byteCount > noteSizePaidMax {
            return "'\(title)' is \(size), over Evernote's \(paid) per-note limit even on a paid plan. Evernote will refuse it."
        }
        return "'\(title)' is \(size), over Evernote's \(free) per-note limit for free accounts. It needs a paid Evernote plan, which raises the limit to \(paid)."
    }
}

// MARK: - Archive Output

/// Default base name for a single-file (concatenated) export.
let concatenatedFileBaseName = "Exported Notes"

/// Where a single-file export should write.
///
/// `destination` is either the file the user named or a directory to put one
/// in, mirroring how a zip destination is resolved.
func concatenatedExportURL(destination: URL, format: ExportFormat) -> URL {
    destination.pathExtension.lowercased() == format.fileExtension
        ? destination
        : destination.appendingPathComponent("\(concatenatedFileBaseName).\(format.fileExtension)")
}

/// The CSS cap that keeps an image inside a PDF's printable area.
///
/// Derived from the real page size and margins. The CLI used to assume a 36pt
/// top and bottom margin regardless of configuration, so any non-default margin
/// gave it a different cap from the app's.
func imageHeightConstraint(forPDF: Bool, pageSize: CGSize?, margins: NSEdgeInsets?) -> String {
    guard forPDF, let pageSize, let margins else { return "" }
    // 20pt of slack so an image never touches the margin.
    let safeMaxHeight = max(100, pageSize.height - margins.top - margins.bottom - 20)
    return "max-height: \(safeMaxHeight)pt; height: auto;"
}
/// One note paired with where it is written and what it is called there.
typealias NoteExportPlacement = (note: NotesNote, folderURL: URL, folderName: String, accountName: String)

/// Flatten the account → folder → notes hierarchy into export order.
///
/// Sorted, because the hierarchy is a `Dictionary` and its iteration order
/// varies between runs of the same process. That order decided the order of a
/// Single File export and, through `buildInternalLinkPathMap`, which of two
/// notes with the same title got the `(2)` suffix — so an export was not
/// reproducible, and two engines exporting the same library disagreed.
func flattenExportHierarchy(
    _ hierarchy: [String: [String: [NotesNote]]],
    outputRoot: URL
) -> [NoteExportPlacement] {
    var placements: [NoteExportPlacement] = []
    for accountName in hierarchy.keys.sorted() {
        guard let folders = hierarchy[accountName] else { continue }
        let accountURL = outputRoot.appendingPathComponent(sanitizeExportFilename(accountName))
        for folderPath in folders.keys.sorted() {
            guard let folderNotes = folders[folderPath] else { continue }
            let folderURL = accountURL.appendingPathComponent(folderPath)
            for note in folderNotes {
                placements.append((note: note, folderURL: folderURL,
                                   folderName: folderPath, accountName: accountName))
            }
        }
    }
    return placements
}

/// The document used when a note's rich body cannot be generated.
///
/// Both engines had their own version of this — the app a styled document, the
/// CLI a bare one — so every export of a note whose protobuf failed to decode
/// differed between them in HTML, and in TeX, RTF and ENEX, which are all
/// converted from it.
func plaintextFallbackHTMLDocument(plaintext: String) -> String {
    return """
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            body { font-family: -apple-system, system-ui; font-size: 12pt; line-height: 1.6; }
            pre { white-space: pre-wrap; word-wrap: break-word; }
        </style>
    </head>
    <body>
        <pre>\(plaintext.htmlEscaped)</pre>
    </body>
    </html>
    """
}


/// The HTML document a single exported note is wrapped in.
///
/// This existed as two copies that had drifted in ways no one would spot by
/// eye: the app centred the content with `margin: <n> auto` and the CLI did
/// not, so CLI and MCP output was left-aligned. Formatting differences also
/// leaked downstream, because TeX, RTF and ENEX pass whitespace through from
/// the HTML they are converted from.
func noteHTMLDocument(
    title: String,
    created: String,
    modified: String,
    fontFamily: String,
    fontSize: String,
    margin: String,
    imageConstraint: String,
    body: String
) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="created" content="\(created)">
        <meta name="modified" content="\(modified)">
        <title>\(title.htmlEscaped)</title>
        <style>
            body {
                font-family: \(fontFamily);
                font-size: \(fontSize);
                max-width: 800px;
                margin: \(margin) auto;
                padding: 0 20px;
                line-height: 1.0;
            }
            /* Remove all spacing around headings and paragraphs */
            h1, h2, h3, h4, h5, h6, p { margin: 0; padding: 0; line-height: 1.0; }
            /* Remove spacing around lists but keep indentation */
            ul, ol { margin: 0; margin-left: 1.5em; padding: 0; padding-left: 0.5em; }
            li { margin: 0; padding: 0; line-height: 1.0; }
            img { max-width: 100%; \(imageConstraint) }
        </style>
    </head>
    <body>
        <div class="content">
            \(body)
        </div>
    </body>
    </html>
    """
}

// MARK: - PDF Layout and Typography Engine

/// Layout profiles supported by the enhanced PDF styling engine.
public enum PDFStyleProfile: String, CaseIterable, Codable, Sendable {
    /// Reproduces the visual aesthetics, colors, and typography recognized by Apple Notes.
    /// Preserves Apple Notes font hierarchies, standard monostyle blocks with subtle borders,
    /// soft yellow/palette highlights, clean table borders, and standard list formatting.
    case faithful = "faithful"

    /// An optimized, highly legible layout engineered for reading, studying, and printing on A4/Letter.
    /// Features comfortable line-height (1.58), clear heading hierarchy with subtle section accents,
    /// elegant technical monostyle callouts with accent bars, centered and proportional images,
    /// soft pastel highlights, styled tables with zebra rows and header repetition, and strict
    /// page-break controls to prevent orphaned headings, sliced images, or cut table rows.
    case study = "study"

    /// User-facing display name.
    public var displayName: String {
        switch self {
        case .faithful: return "Faithful"
        case .study: return "Study"
        }
    }

    /// Descriptive explanation of the profile's characteristics.
    public var description: String {
        switch self {
        case .faithful:
            return "Faithful to Apple Notes: preserves native typography, monostyle, highlights, and note layout."
        case .study:
            return "Study Guide: clean A4 layout, comfortable line-height, centered proportional images, and page-break protection."
        }
    }
}

/// Compatibility alias matching both naming conventions.
public typealias PDFLayoutProfile = PDFStyleProfile

/// Configuration options for PDF layout rendering.
public struct PDFDocumentOptions: Sendable, Equatable {
    /// The target visual styling profile (faithful or study).
    public var profile: PDFStyleProfile
    /// Paper size in points (e.g. A4 is 595 x 842 pt; Letter is 612 x 792 pt).
    public var pageSize: CGSize
    /// Margin insets in points (top, left, bottom, right).
    public var pageMargins: NSEdgeInsets
    /// Optional font family override (CSS font-family string). If nil, profile default is used.
    public var fontFamily: String?
    /// Base font size in points. If nil, profile default is used.
    public var baseFontSizePoints: Double?
    /// Optional custom accent color (hex/rgb string, e.g. "#2563eb").
    public var accentColor: String?
    /// Whether to force image centering (if nil, uses profile default: true for study, false for faithful).
    public var centerImages: Bool?
    /// Maximum image width as percentage of printable width (if nil, uses profile default: 85% for study, 100% for faithful).
    public var maxImageWidthPercent: Double?
    /// When true, @page margin in CSS sets the page margins directly. When false (default), CSS assumes margins are handled by the print runner (e.g. NSPrintInfo in HtmlToPdf).
    public var embedPageMarginsInCSS: Bool
    /// Whether to include document metadata header (e.g. title/date badge).
    public var showHeader: Bool
    /// Additional custom CSS rules to inject if needed.
    public var customCSS: String?

    public init(
        profile: PDFStyleProfile = .study,
        pageSize: CGSize = CGSize(width: 595, height: 842),
        pageMargins: NSEdgeInsets = NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
        fontFamily: String? = nil,
        baseFontSizePoints: Double? = nil,
        accentColor: String? = nil,
        centerImages: Bool? = nil,
        maxImageWidthPercent: Double? = nil,
        embedPageMarginsInCSS: Bool = false,
        showHeader: Bool = false,
        customCSS: String? = nil
    ) {
        self.profile = profile
        self.pageSize = pageSize
        self.pageMargins = pageMargins
        self.fontFamily = fontFamily
        self.baseFontSizePoints = baseFontSizePoints
        self.accentColor = accentColor
        self.centerImages = centerImages
        self.maxImageWidthPercent = maxImageWidthPercent
        self.embedPageMarginsInCSS = embedPageMarginsInCSS
        self.showHeader = showHeader
        self.customCSS = customCSS
    }

    public static func == (lhs: PDFDocumentOptions, rhs: PDFDocumentOptions) -> Bool {
        lhs.profile == rhs.profile &&
        lhs.pageSize.width == rhs.pageSize.width &&
        lhs.pageSize.height == rhs.pageSize.height &&
        lhs.pageMargins.top == rhs.pageMargins.top &&
        lhs.pageMargins.left == rhs.pageMargins.left &&
        lhs.pageMargins.bottom == rhs.pageMargins.bottom &&
        lhs.pageMargins.right == rhs.pageMargins.right &&
        lhs.fontFamily == rhs.fontFamily &&
        lhs.baseFontSizePoints == rhs.baseFontSizePoints &&
        lhs.accentColor == rhs.accentColor &&
        lhs.centerImages == rhs.centerImages &&
        lhs.maxImageWidthPercent == rhs.maxImageWidthPercent &&
        lhs.embedPageMarginsInCSS == rhs.embedPageMarginsInCSS &&
        lhs.showHeader == rhs.showHeader &&
        lhs.customCSS == rhs.customCSS
    }

    /// Default configuration for Study profile on A4 paper.
    public static var a4Study: PDFDocumentOptions {
        PDFDocumentOptions(
            profile: .study,
            pageSize: CGSize(width: 595, height: 842),
            pageMargins: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
            baseFontSizePoints: 10.5,
            centerImages: true,
            maxImageWidthPercent: 85.0
        )
    }

    /// Default configuration for Faithful profile on A4 paper.
    public static var a4Faithful: PDFDocumentOptions {
        PDFDocumentOptions(
            profile: .faithful,
            pageSize: CGSize(width: 595, height: 842),
            pageMargins: NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
            baseFontSizePoints: 11.0,
            centerImages: false,
            maxImageWidthPercent: 100.0
        )
    }
}

/// Compatibility alias matching both naming conventions.
public typealias PDFLayoutOptions = PDFDocumentOptions

/// Generates CSS constraint for maximum image height based on page size and margins.
public func pdfImageConstraint(
    profile: PDFStyleProfile,
    pageSize: CGSize? = nil,
    margins: NSEdgeInsets? = nil
) -> String {
    let printableHeight: CGFloat
    if let pageSize, let margins {
        printableHeight = max(100, pageSize.height - margins.top - margins.bottom - 20)
    } else {
        printableHeight = 750
    }

    switch profile {
    case .faithful:
        return "max-height: \(printableHeight)pt; height: auto;"
    case .study:
        let studyMaxHeight = min(380, max(120, printableHeight * 0.48))
        return "max-height: \(studyMaxHeight)pt; height: auto;"
    }
}

/// Generates the standalone CSS stylesheet for the requested PDF layout profile and options.
public func pdfDocumentCSS(options: PDFDocumentOptions) -> String {
    let profile = options.profile
    let safeMaxHeight: CGFloat
    if profile == .study {
        let printableHeight = max(100, options.pageSize.height - options.pageMargins.top - options.pageMargins.bottom - 20)
        safeMaxHeight = min(380, max(120, printableHeight * 0.48))
    } else {
        safeMaxHeight = max(100, options.pageSize.height - options.pageMargins.top - options.pageMargins.bottom - 20)
    }

    let shouldCenterImages = options.centerImages ?? (profile == .study)
    let maxImageWidth = options.maxImageWidthPercent ?? (profile == .study ? 85.0 : 100.0)

    let pageMarginRule: String
    if options.embedPageMarginsInCSS {
        pageMarginRule = "margin: \(options.pageMargins.top)pt \(options.pageMargins.right)pt \(options.pageMargins.bottom)pt \(options.pageMargins.left)pt;"
    } else {
        pageMarginRule = "margin: 0;"
    }

    switch profile {
    case .faithful:
        let fontFamily = options.fontFamily ?? "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif"
        let fontSize = options.baseFontSizePoints ?? 11.0
        let linkColor = options.accentColor ?? "#0071e3"

        return """
        /* Apple Notes Exporter — Faithful PDF Profile */
        @page {
            size: \(options.pageSize.width)pt \(options.pageSize.height)pt;
            \(pageMarginRule)
        }
        *, *:before, *:after {
            -webkit-print-color-adjust: exact !important;
            print-color-adjust: exact !important;
            box-sizing: border-box;
        }
        html, body {
            margin: 0;
            padding: 0;
            background: #ffffff;
            color: #000000;
            font-family: \(fontFamily);
            font-size: \(fontSize)pt;
            line-height: 1.4;
            word-wrap: break-word;
            overflow-wrap: break-word;
            -webkit-text-size-adjust: 100%;
        }
        .ane-content {
            padding: 0;
            margin: 0;
        }

        /* Headings */
        h1, h2, h3, h4, h5, h6 {
            color: #000000;
            break-after: avoid !important;
            page-break-after: avoid !important;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        h1 {
            font-size: 20pt;
            font-weight: 700;
            margin: 0.5em 0 0.35em 0;
            line-height: 1.25;
        }
        h2 {
            font-size: 15pt;
            font-weight: 600;
            margin: 0.6em 0 0.3em 0;
            line-height: 1.3;
        }
        h3 {
            font-size: 12.5pt;
            font-weight: 600;
            margin: 0.5em 0 0.25em 0;
            line-height: 1.35;
        }
        p {
            margin: 0 0 0.5em 0;
            line-height: 1.4;
            orphans: 2;
            widows: 2;
        }

        /* Monostile */
        pre, pre.ane-monostyle, .ane-monostyle {
            font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace !important;
            font-size: 0.92em !important;
            line-height: 1.42 !important;
            background-color: #f4f4f6 !important;
            border: 1px solid #e5e5ea !important;
            border-radius: 6px !important;
            padding: 8px 12px !important;
            margin: 8px 0 12px 0 !important;
            white-space: pre-wrap !important;
            word-wrap: break-word !important;
            overflow-wrap: break-word !important;
            tab-size: 4;
            -moz-tab-size: 4;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
            color: #000000 !important;
        }
        code {
            font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 0.9em;
            background-color: #f0f0f2;
            padding: 1.5px 4px;
            border-radius: 3px;
        }

        /* Highlights */
        mark, .ane-highlight {
            background-color: #ffe58f !important;
            color: inherit;
            padding: 0.1em 0.25em;
            border-radius: 3px;
            -webkit-box-decoration-break: clone;
            box-decoration-break: clone;
        }
        .ane-highlight-yellow { background-color: #ffe58f !important; }
        .ane-highlight-amber, .ane-highlight-orange { background-color: #ffd591 !important; }
        .ane-highlight-pink, .ane-highlight-red { background-color: #ffadd2 !important; }
        .ane-highlight-purple { background-color: #d3adf7 !important; }
        .ane-highlight-blue { background-color: #bae7ff !important; }
        .ane-highlight-green, .ane-highlight-mint { background-color: #b7eb8f !important; }
        .ane-highlight-gray { background-color: #e8e8e8 !important; }

        /* Text colors */
        .ane-color-yellow { color: #b45309 !important; }
        .ane-color-green { color: #15803d !important; }
        .ane-color-pink { color: #be185d !important; }
        .ane-color-purple { color: #7e22ce !important; }
        .ane-color-blue { color: #1d4ed8 !important; }
        .ane-color-gray { color: #6b7280 !important; }
        .ane-color-orange { color: #c2410c !important; }
        .ane-color-red { color: #b91c1c !important; }

        /* Lists */
        ul, ol {
            margin: 0.3em 0 0.6em 0;
            padding-left: 1.5em;
        }
        li {
            margin: 0.15em 0;
            line-height: 1.4;
        }
        ul[style*="list-style-type: none"], ul.ane-checklist {
            padding-left: 0.4em;
            list-style: none;
        }

        /* Tables */
        table, .ane-table {
            border-collapse: collapse !important;
            width: 100%;
            margin: 12px 0 16px 0;
            break-inside: auto;
            page-break-inside: auto;
        }
        thead {
            display: table-header-group;
        }
        tr {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        td, th {
            border: 1px solid #d2d2d7 !important;
            padding: 6px 10px !important;
            text-align: left;
            vertical-align: top;
            line-height: 1.35;
        }
        th {
            background-color: #f7f7f8 !important;
            font-weight: 600;
        }

        /* Images */
        img {
            max-width: \(maxImageWidth)% !important;
            max-height: \(safeMaxHeight)pt !important;
            height: auto !important;
            display: block;
            margin: \(shouldCenterImages ? "12px auto" : "10px 0") !important;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
            object-fit: contain;
            border-radius: 4px;
        }
        a:has(> img), .ane-image-container {
            display: block;
            \(shouldCenterImages ? "text-align: center; margin: 12px auto;" : "margin: 10px 0;")
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }

        /* Links & Cards */
        a {
            color: \(linkColor);
            text-decoration: underline;
            text-underline-offset: 2px;
        }
        div[style*="border: 1px solid"], .ane-url-card, .ane-attachment {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
            margin: 8px 0;
        }

        /* Paging utilities */
        .page-break, .page-break-before {
            break-before: page !important;
            page-break-before: always !important;
        }
        .page-break-after {
            break-after: page !important;
            page-break-after: always !important;
        }
        .no-break, .keep-together {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        \(options.customCSS ?? "")
        """

    case .study:
        let fontFamily = options.fontFamily ?? "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
        let fontSize = options.baseFontSizePoints ?? 10.5
        let accentColor = options.accentColor ?? "#2563eb"

        return """
        /* Apple Notes Exporter — Study PDF Profile */
        @page {
            size: \(options.pageSize.width)pt \(options.pageSize.height)pt;
            \(pageMarginRule)
        }
        *, *:before, *:after {
            -webkit-print-color-adjust: exact !important;
            print-color-adjust: exact !important;
            box-sizing: border-box;
        }
        html, body {
            margin: 0;
            padding: 0;
            background: #ffffff;
            color: #1e293b;
            font-family: \(fontFamily);
            font-size: \(fontSize)pt;
            line-height: 1.58;
            letter-spacing: 0.005em;
            word-wrap: break-word;
            overflow-wrap: break-word;
            -webkit-text-size-adjust: 100%;
        }
        .ane-content {
            padding: 0;
            margin: 0;
        }

        /* Headings Hierarchy */
        h1, h2, h3, h4, h5, h6 {
            color: #0f172a;
            break-after: avoid !important;
            page-break-after: avoid !important;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        h1 {
            font-size: 21pt;
            font-weight: 700;
            color: #0f172a;
            line-height: 1.25;
            margin: 1.5em 0 0.5em 0;
            padding-bottom: 0.25em;
            border-bottom: 2px solid #e2e8f0;
            letter-spacing: -0.02em;
        }
        h1:first-child, .ane-content > h1:first-child {
            margin-top: 0;
        }
        h2 {
            font-size: 15pt;
            font-weight: 600;
            color: #1e293b;
            line-height: 1.3;
            margin: 1.35em 0 0.45em 0;
            padding-bottom: 0.18em;
            border-bottom: 1px solid #f1f5f9;
            letter-spacing: -0.01em;
        }
        h3 {
            font-size: 12.5pt;
            font-weight: 600;
            color: #334155;
            line-height: 1.35;
            margin: 1.1em 0 0.35em 0;
        }
        p {
            margin: 0 0 0.85em 0;
            line-height: 1.58;
            orphans: 3;
            widows: 3;
        }

        /* Monostile Callout */
        pre, pre.ane-monostyle, .ane-monostyle {
            font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace !important;
            font-size: 0.88em !important;
            line-height: 1.5 !important;
            background-color: #f8fafc !important;
            border: 1px solid #e2e8f0 !important;
            border-left: 3.5px solid \(accentColor) !important;
            border-radius: 6px !important;
            padding: 10px 14px !important;
            margin: 12px 0 16px 0 !important;
            color: #0f172a !important;
            white-space: pre-wrap !important;
            word-wrap: break-word !important;
            overflow-wrap: break-word !important;
            tab-size: 4;
            -moz-tab-size: 4;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        code {
            font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
            font-size: 0.88em;
            background-color: #f1f5f9;
            color: #0f172a;
            padding: 1.5px 5px;
            border-radius: 4px;
            border: 1px solid #e2e8f0;
        }

        /* Highlights */
        mark, .ane-highlight {
            background-color: #fef08a !important;
            color: inherit;
            padding: 0.12em 0.35em;
            border-radius: 3px;
            -webkit-box-decoration-break: clone;
            box-decoration-break: clone;
        }
        .ane-highlight-yellow { background-color: #fef08a !important; }
        .ane-highlight-amber, .ane-highlight-orange { background-color: #fed7aa !important; }
        .ane-highlight-pink, .ane-highlight-red { background-color: #fbcfe8 !important; }
        .ane-highlight-purple { background-color: #e9d5ff !important; }
        .ane-highlight-blue { background-color: #bfdbfe !important; }
        .ane-highlight-green, .ane-highlight-mint { background-color: #bbf7d0 !important; }
        .ane-highlight-gray { background-color: #e2e8f0 !important; }

        /* Text colors */
        .ane-color-yellow { color: #b45309 !important; }
        .ane-color-green { color: #15803d !important; }
        .ane-color-pink { color: #be185d !important; }
        .ane-color-purple { color: #7e22ce !important; }
        .ane-color-blue { color: #1d4ed8 !important; }
        .ane-color-gray { color: #64748b !important; }
        .ane-color-orange { color: #c2410c !important; }
        .ane-color-red { color: #b91c1c !important; }

        /* Lists */
        ul, ol {
            margin: 0.5em 0 0.85em 0;
            padding-left: 1.6em;
        }
        li {
            margin-bottom: 0.3em;
            line-height: 1.58;
            break-inside: avoid;
            page-break-inside: avoid;
        }
        ul[style*="list-style-type: none"], ul.ane-checklist {
            padding-left: 0.4em;
            list-style: none;
        }

        /* Tables with Row Page-Break Avoidance & Zebra Striping */
        table, .ane-table {
            border-collapse: collapse !important;
            width: 100%;
            margin: 16px 0 20px 0;
            border: 1px solid #cbd5e1 !important;
            border-radius: 6px;
            overflow: hidden;
            break-inside: auto;
            page-break-inside: auto;
        }
        thead {
            display: table-header-group;
        }
        tr {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        table tr:first-child td, table th {
            background-color: #f1f5f9 !important;
            font-weight: 600 !important;
            color: #0f172a;
            border-bottom: 2px solid #cbd5e1 !important;
        }
        td, th {
            border: 1px solid #e2e8f0 !important;
            padding: 8px 12px !important;
            text-align: left;
            vertical-align: top;
            line-height: 1.45;
            font-size: 0.95em;
        }
        table tr:nth-child(even):not(:first-child) td {
            background-color: #f8fafc;
        }

        /* Centered & Proportional Images */
        img {
            display: block !important;
            margin: 18px auto !important;
            max-width: \(maxImageWidth)% !important;
            max-height: \(safeMaxHeight)pt !important;
            height: auto !important;
            width: auto !important;
            object-fit: contain;
            border-radius: 6px;
            box-shadow: 0 1px 4px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.04);
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        a:has(> img), .ane-image-container {
            display: block;
            text-align: center;
            margin: 18px auto;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }

        /* Links & Cards */
        a {
            color: \(accentColor);
            text-decoration: none;
            border-bottom: 1px solid #93c5fd;
            padding-bottom: 0.5px;
        }
        div[style*="border: 1px solid"], .ane-url-card, .ane-attachment {
            border: 1px solid #e2e8f0 !important;
            background-color: #f8fafc !important;
            border-radius: 8px !important;
            padding: 10px 14px !important;
            margin: 10px 0 14px 0 !important;
            break-inside: avoid !important;
            page-break-inside: avoid !important;
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
        }

        /* Paging utilities */
        .page-break, .page-break-before {
            break-before: page !important;
            page-break-before: always !important;
        }
        .page-break-after {
            break-after: page !important;
            page-break-after: always !important;
        }
        .no-break, .keep-together {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
        }
        \(options.customCSS ?? "")
        """
    }
}

/// Convenience overload for pdfDocumentCSS using default options for the given profile, paper size, and margins.
public func pdfDocumentCSS(
    profile: PDFStyleProfile,
    fontFamily: String? = nil,
    fontSize: String? = nil,
    pageSize: CGSize = CGSize(width: 595, height: 842),
    margins: NSEdgeInsets = NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
) -> String {
    var options = PDFDocumentOptions(profile: profile, pageSize: pageSize, pageMargins: margins)
    if let fontFamily, !fontFamily.isEmpty { options.fontFamily = fontFamily }
    if let fontSize, let parsedSize = Double(fontSize.replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespaces)) {
        options.baseFontSizePoints = parsedSize
    }
    return pdfDocumentCSS(options: options)
}

/// Safely extracts the inner content of an HTML document body if full html/body tags are present;
/// otherwise returns the input string unchanged.
public func extractHTMLBodyContent(_ html: String) -> String {
    guard let bodyStart = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
        return html
    }
    let afterOpen = html[bodyStart.upperBound...]
    guard let bodyEnd = afterOpen.range(of: "</body>", options: [.caseInsensitive, .backwards]) else {
        return String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(afterOpen[..<bodyEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Generates a complete, standalone HTML document styled for high-quality PDF rendering
/// using the specified profile and options.
enum PDFDocumentSecurityPolicy {
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
}

public func notePDFHTMLDocument(
    title: String,
    created: String = "",
    modified: String = "",
    options: PDFDocumentOptions = .a4Study,
    body: String
) -> String {
    let css = pdfDocumentCSS(options: options)
    let bodyContent = extractHTMLBodyContent(body)

    let headerHTML: String
    if options.showHeader {
        let createdMeta = created.isEmpty ? "" : "<span class=\"ane-meta-created\">Created: \(created.htmlEscaped)</span>"
        let modifiedMeta = modified.isEmpty ? "" : "<span class=\"ane-meta-modified\">Modified: \(modified.htmlEscaped)</span>"
        let metaRow = [createdMeta, modifiedMeta].filter { !$0.isEmpty }.joined(separator: " • ")
        headerHTML = """
        <header class="ane-document-header" style="border-bottom: 2px solid #e2e8f0; padding-bottom: 10px; margin-bottom: 20px; break-inside: avoid;">
            <h1 class="ane-document-title" style="margin: 0 0 6px 0;">\(title.htmlEscaped)</h1>
            \(metaRow.isEmpty ? "" : "<div class=\"ane-document-meta\" style=\"font-size: 9pt; color: #64748b;\">\(metaRow)</div>")
        </header>
        """
    } else {
        headerHTML = ""
    }

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="Content-Security-Policy" content="\(PDFDocumentSecurityPolicy.contentSecurityPolicy)">
        <meta name="created" content="\(created.htmlEscaped)">
        <meta name="modified" content="\(modified.htmlEscaped)">
        <meta name="ane-profile" content="\(options.profile.rawValue)">
        <title>\(title.htmlEscaped)</title>
        <style>
    \(css)
        </style>
    </head>
    <body class="ane-pdf-document ane-profile-\(options.profile.rawValue)">
        <div class="content ane-content">
            \(headerHTML)\(bodyContent)
        </div>
    </body>
    </html>
    """
}

/// Convenience overload for notePDFHTMLDocument accepting profile, paper size, and margins.
public func notePDFHTMLDocument(
    title: String,
    created: String = "",
    modified: String = "",
    profile: PDFStyleProfile = .study,
    fontFamily: String? = nil,
    fontSize: String? = nil,
    pageSize: CGSize = CGSize(width: 595, height: 842),
    margins: NSEdgeInsets = NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
    body: String
) -> String {
    var options = PDFDocumentOptions(profile: profile, pageSize: pageSize, pageMargins: margins)
    if let fontFamily, !fontFamily.isEmpty { options.fontFamily = fontFamily }
    if let fontSize, let parsedSize = Double(fontSize.replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespaces)) {
        options.baseFontSizePoints = parsedSize
    }
    return notePDFHTMLDocument(title: title, created: created, modified: modified, options: options, body: body)
}

/// Compatibility adapter matching noteHTMLDocument parameter style for easy integration into existing export coordinators.
public func notePDFHTMLDocument(
    title: String,
    created: String,
    modified: String,
    fontFamily: String?,
    fontSize: String?,
    margin: String?,
    imageConstraint: String?,
    profile: PDFStyleProfile,
    pageSize: CGSize? = nil,
    margins: NSEdgeInsets? = nil,
    body: String
) -> String {
    var options = (profile == .study) ? PDFDocumentOptions.a4Study : PDFDocumentOptions.a4Faithful
    if let pageSize { options.pageSize = pageSize }
    if let margins { options.pageMargins = margins }
    if let fontFamily, !fontFamily.isEmpty { options.fontFamily = fontFamily }
    if let fontSize, let parsedSize = Double(fontSize.replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespaces)) {
        options.baseFontSizePoints = parsedSize
    }
    return notePDFHTMLDocument(title: title, created: created, modified: modified, options: options, body: body)
}

/// Alias for notePDFHTMLDocument supporting alternative integration calls.
public func pdfHTMLDocument(
    title: String,
    created: String = "",
    modified: String = "",
    options: PDFDocumentOptions = .a4Study,
    body: String
) -> String {
    notePDFHTMLDocument(title: title, created: created, modified: modified, options: options, body: body)
}

/// Alias for notePDFHTMLDocument supporting alternative integration calls.
public func pdfHTMLDocument(
    title: String,
    created: String = "",
    modified: String = "",
    profile: PDFStyleProfile,
    pageSize: CGSize = CGSize(width: 595, height: 842),
    margins: NSEdgeInsets = NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
    body: String
) -> String {
    notePDFHTMLDocument(title: title, created: created, modified: modified, profile: profile, pageSize: pageSize, margins: margins, body: body)
}

///
/// Most formats want exactly what the user configured. Two do not, and the app
/// knew that while the CLI did not: `--format markdown` from the CLI wrote
/// multi-megabyte base64 data URIs into the .md where the app wrote
/// `![](Note (Attachments)/img.jpg)`.
///
/// Exhaustive on purpose: a new format has to state which side it falls on.
func htmlConfiguration(for format: ExportFormat, base: HTMLConfiguration) -> HTMLConfiguration {
    var config = base
    switch format {
    case .txt:
        // Plain text has nowhere to put an image, so building the inline
        // base64 only for the converter to strip it is wasted work.
        config.embedImagesInline = false
        config.linkEmbeddedImages = false
    case .markdown:
        // Markdown links the exported file rather than carrying the bytes.
        config.embedImagesInline = false
        config.linkEmbeddedImages = true
    case .html, .pdf, .rtf, .tex, .json, .jsonl, .xml, .csv,
         .opml, .org, .rst, .adoc, .enex, .docx, .odt, .epub:
        break
    }
    return config
}

/// Every file extension this app writes, archives included.
///
/// Used to tell "the user named the output file" from "the user named a
/// directory that happens to contain a dot". Derived rather than listed: the
/// MCP copy of this set was written out by hand as `["zip"]` and silently
/// missed `tar` when the TAR destination was added.
let exportProducedExtensions: Set<String> = Set(ExportFormat.allCases.map(\.fileExtension))
    .union(ExportArchiveFormat.allCases.map(\.fileExtension))

/// The id set that "this note was deleted from Apple Notes" is judged against,
/// or nil when pruning must be skipped this run.
///
/// Pruning deletes exported files, so it is only ever safe against the whole
/// library. When the library could not be read, this returns nil rather than
/// falling back to the current selection: judging deletion against a subset
/// would delete the exported files of every note the user simply did not
/// select this time.
func prunePresentNoteIds(libraryNoteIds: Set<String>?, selectedNoteIds: [String]) -> Set<String>? {
    guard let libraryNoteIds else { return nil }
    return libraryNoteIds.union(selectedNoteIds)
}

/// Best-effort MIME type for a file extension, for embedding a file in a
/// container format that has to declare one. Unknown types fall back to the
/// generic binary type rather than being dropped.
func mimeType(forPathExtension ext: String) -> String {
    guard !ext.isEmpty,
          let type = UTType(filenameExtension: ext.lowercased()),
          let mime = type.preferredMIMEType else {
        return "application/octet-stream"
    }
    return mime
}

/// Attachments the exported HTML links to, read back so they can be carried
/// inside a single-document format instead of as sibling files.
///
/// Only paths the markup actually references are included: an image embedded
/// inline is already a resource, and emitting it again would attach the same
/// bytes to the note twice.
func linkedAttachmentResources(
    linkedIn html: String,
    paths: [String: String],
    outputRoot: URL?
) -> [ENEXResource] {
    guard let outputRoot else { return [] }
    var seen = Set<String>()
    var resources: [ENEXResource] = []

    for relativePath in paths.values.sorted() {
        guard seen.insert(relativePath).inserted else { continue }
        guard html.contains("href=\"\(relativePath.htmlEscaped)\"")
                || html.contains("href=\"\(relativePath)\"") else { continue }

        let fileURL = outputRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { continue }

        resources.append(ENEXResource(
            data: data,
            mime: mimeType(forPathExtension: fileURL.pathExtension),
            filename: fileURL.lastPathComponent,
            relativePath: relativePath
        ))
    }
    return resources
}

/// Joins per-note output into the one file a Single File export produces.
///
/// The app and the CLI each had their own copy of this, and they had drifted:
/// the CLI had no case for ENEX (so notes were joined with a Markdown rule
/// inside XML) and applied neither the JSON array nor the CSV header. Both now
/// go through here so a format only has to be described once.
enum ConcatenatedExport {

    /// What goes between two notes. Formats that are a single structured
    /// document get their separator from the syntax; prose formats get a
    /// visible divider.
    static func separator(for format: ExportFormat) -> String {
        switch format {
        case .html, .pdf:
            return "\n<hr style=\"page-break-after: always;\">\n"
        case .markdown:
            return "\n\n---\n\n"
        case .txt:
            return "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        case .rtf:
            return "\n\\page\n"
        case .tex:
            return "\n\n\\newpage\n\n"
        case .json:
            return ",\n"                                    // array elements
        case .org:
            return "\n\n" + String(repeating: "-", count: 72) + "\n\n"
        case .rst:
            return "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        case .adoc:
            return "\n\n'''\n\n"                            // thematic break
        case .jsonl, .xml, .csv, .opml, .enex:
            return "\n"
        case .docx, .odt, .epub:
            return ""                                       // cannot be joined
        }
    }

    /// The joined notes plus whatever wrapper the format's syntax requires.
    ///
    /// `parts` for ENEX must be `<note>` elements rather than whole documents,
    /// since the `<en-export>` root is added here exactly once.
    /// Exhaustive on purpose, and for the same reason as `separator(for:)`: a
    /// format that needs a document wrapper must not get one by omission. This
    /// is the shape that let concatenated ENEX ship as several XML documents
    /// glued together.
    static func assemble(_ parts: [String], format: ExportFormat) -> String {
        let joined = parts.joined(separator: separator(for: format))
        switch format {
        case .json:
            return "[\n" + joined + "\n]"
        case .csv:
            return NotesNote.csvHeader() + "\n" + joined
        case .enex:
            return ENEXDocument.wrap(joined)
        case .xml:
            return XMLNotesDocument.wrap(joined)
        case .opml:
            return OPMLDocument.wrap(joined)
        case .html, .txt, .markdown, .rtf, .tex, .jsonl,
             .org, .rst, .adoc:
            return joined                       // no wrapper: notes just abut
        case .pdf, .docx, .odt, .epub:
            return joined                       // never concatenated; see supportsConcatenation
        }
    }
}

/// Default root name for an archive export: both the folder inside the archive
/// and the archive itself when the user has not named one.
let exportArchiveRootName = "Apple Notes Export"

/// Archive containers the exporter can deliver.
enum ExportArchiveFormat: String, CaseIterable {
    case zip
    case tar

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .zip: return "ZIP Archive"
        case .tar: return "TAR Archive"
        }
    }

    var systemImage: String {
        switch self {
        case .zip: return "doc.zipper"
        case .tar: return "shippingbox"
        }
    }
}

/// Write `sourceURL` (a directory) into an archive at `destinationURL`.
func createArchive(_ format: ExportArchiveFormat, at sourceURL: URL, to destinationURL: URL) throws {
    switch format {
    case .zip: try zipDirectory(at: sourceURL, to: destinationURL)
    case .tar: try tarDirectory(at: sourceURL, to: destinationURL)
    }
}

/// Tar `sourceURL` (a directory) to `destinationURL`.
///
/// Uses bsdtar with -C so the archive contains the folder itself rather than an
/// absolute path, matching the layout the zip export produces. tar records each
/// entry's modification time, so the note dates the exporter stamps on every
/// file survive being unpacked.
func tarDirectory(at sourceURL: URL, to destinationURL: URL) throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = [
        "-cf", destinationURL.path,
        "-C", sourceURL.deletingLastPathComponent().path,
        sourceURL.lastPathComponent
    ]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = Pipe()

    try process.run()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let detail = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw NSError(domain: "AppleNotesExporter", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: detail.isEmpty
                ? "tar exited with status \(process.terminationStatus)."
                : "tar failed: \(detail)"
        ])
    }
}

/// Zip `sourceURL` (a directory) to `destinationURL`.
///
/// NSFileCoordinator's .forUploading intent is what Finder's "Compress" uses,
/// so the archive matches what a user would produce by hand. Synchronous and
/// throwing: the caller needs to know whether the artifact was actually
/// written before it reports success and deletes the staging directory.
func zipDirectory(at sourceURL: URL, to destinationURL: URL) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var writeError: Error?

    coordinator.coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &coordinationError) { zippedURL in
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
        } catch {
            writeError = error
        }
    }

    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
}

/// A path in `directory` that collides with nothing already there.
func uniqueExportURL(in directory: URL, baseName: String, extension ext: String?) -> URL {
    func candidate(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        return ext.map { url.appendingPathExtension($0) } ?? url
    }
    var url = candidate(baseName)
    var counter = 2
    while FileManager.default.fileExists(atPath: url.path), counter <= 1000 {
        url = candidate("\(baseName) (\(counter))")
        counter += 1
    }
    return url
}

/// Resolve where a zip export should stage its files and write its archive.
///
/// `destination` is either the archive the user named or a folder to put one
/// in. The archive's own name becomes the root folder inside it.
func archiveExportLocations(destination: URL, format: ExportArchiveFormat = .zip) -> (staging: URL, archive: URL) {
    let archive = destination.pathExtension.lowercased() == format.fileExtension
        ? destination
        : uniqueExportURL(in: destination, baseName: exportArchiveRootName, extension: format.fileExtension)
    let rootName = archive.deletingPathExtension().lastPathComponent
    let staging = uniqueExportURL(
        in: archive.deletingLastPathComponent(), baseName: rootName, extension: nil
    )
    return (staging, archive)
}

/// Generate a unique filename by appending a counter suffix if a collision exists.
func generateUniqueExportFilename(baseName: String, extension ext: String, inDirectory directory: URL) -> String {
    let initial = "\(baseName).\(ext)"
    // HTML exports write index.html as a folder listing; never let a note claim that name.
    let reserved = ext.lowercased() == "html" && initial.lowercased() == "index.html"
    if !reserved && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(initial).path) {
        return initial
    }
    var counter = 2
    while counter <= 10000 {
        let candidate = "\(baseName) (\(counter)).\(ext)"
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            return candidate
        }
        counter += 1
    }
    return "\(baseName)_\(UUID().uuidString).\(ext)"
}

/// Split a filename into name and extension at the last dot.
func splitExportFilename(_ filename: String) -> (name: String, ext: String) {
    if let lastDot = filename.lastIndex(of: "."), lastDot != filename.startIndex {
        return (String(filename[..<lastDot]), String(filename[filename.index(after: lastDot)...]))
    }
    return (filename, "")
}

/// Set file creation and modification timestamps.
func setExportFileTimestamps(_ fileURL: URL, creationDate: Date, modificationDate: Date) throws {
    try FileManager.default.setAttributes([
        .creationDate: creationDate,
        .modificationDate: modificationDate
    ], ofItemAtPath: fileURL.path)
}

/// Set folder timestamps based on the oldest creation and latest modification dates of notes within.
func setExportFolderTimestamps(hierarchy: [String: [String: [NotesNote]]], outputURL: URL) throws {
    for (accountName, folders) in hierarchy {
        let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
        var accountOldest: Date?
        var accountLatest: Date?

        for (folderPath, notes) in folders {
            guard !notes.isEmpty else { continue }
            let folderURL = accountURL.appendingPathComponent(folderPath)
            let oldest = notes.map { $0.creationDate }.min() ?? Date()
            let latest = notes.map { $0.modificationDate }.max() ?? Date()
            try setExportFileTimestamps(folderURL, creationDate: oldest, modificationDate: latest)
            if accountOldest == nil || oldest < accountOldest! { accountOldest = oldest }
            if accountLatest == nil || latest > accountLatest! { accountLatest = latest }
        }
        if let o = accountOldest, let l = accountLatest {
            try setExportFileTimestamps(accountURL, creationDate: o, modificationDate: l)
        }
    }
}

/// Attachment UTI prefixes that represent inline/non-file content (not exported as files).
let nonFileAttachmentPrefixes: [String] = [
    "com.apple.notes.table",
    "com.apple.notes.inlinetextattachment",
    "com.apple.notes.inlinehashtagattachment",
    "com.apple.notes.inlinementionattachment",
    "public.url"
]

/// Split comma-separated CLI tokens, also flattening repeated --folder values.
func parseListArgument(_ values: [String]) -> [String] {
    values.flatMap { raw in
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }.filter { !$0.isEmpty }
}

func parseListArgument(_ value: String?) -> [String] {
    guard let value else { return [] }
    return parseListArgument([value])
}

/// True when a filter refers to Apple Notes' Recently Deleted smart folder.
func isRecentlyDeletedFolderName(_ name: String) -> Bool {
    name.compare("Recently Deleted", options: .caseInsensitive) == .orderedSame
}

/// Folder IDs matching `filters` (comma-separated or repeated).
/// Default match is exact folder id or case-insensitive exact name.
/// `matchContains` restores substring matching. Descendants are included unless disabled.
func matchingFolderIds(
    filters: [String],
    folders: [NotesFolder],
    matchContains: Bool = false,
    includeDescendants: Bool = true
) -> Set<String> {
    let tokens = parseListArgument(filters)
    guard !tokens.isEmpty else { return [] }

    var matched: Set<String> = []
    for token in tokens {
        if isRecentlyDeletedFolderName(token) { continue }
        let lowered = token.lowercased()
        let hits = folders.filter { folder in
            folder.id.caseInsensitiveCompare(token) == .orderedSame
                || folder.name.compare(token, options: .caseInsensitive) == .orderedSame
                || (matchContains && folder.name.lowercased().contains(lowered))
        }
        for folder in hits { matched.insert(folder.id) }
    }

    guard !matched.isEmpty else { return matched }
    guard includeDescendants else { return matched }

    var childrenByParent: [String: [String]] = [:]
    for folder in folders {
        if let parent = folder.parentId {
            childrenByParent[parent, default: []].append(folder.id)
        }
    }

    var stack = Array(matched)
    while let current = stack.popLast() {
        for child in childrenByParent[current] ?? [] {
            if matched.insert(child).inserted {
                stack.append(child)
            }
        }
    }
    return matched
}

func matchingFolderIds(filter: String, folders: [NotesFolder]) -> Set<String> {
    matchingFolderIds(filters: [filter], folders: folders, matchContains: false, includeDescendants: true)
}

/// Folder filters the user asked for that match no folder in the library.
///
/// An empty match set is indistinguishable from "no filter requested" once it
/// reaches `selectedNotes`, so a mistyped `--folder` would otherwise select the
/// whole library instead of nothing. Callers use this to fail loudly instead.
/// The Recently Deleted smart folder is not a real folder row, so it never
/// counts as unmatched.
func unmatchedFolderFilters(
    filters: [String],
    folders: [NotesFolder],
    matchContains: Bool = false
) -> [String] {
    parseListArgument(filters).filter { token in
        if isRecentlyDeletedFolderName(token) { return false }
        let lowered = token.lowercased()
        return !folders.contains { folder in
            folder.id.caseInsensitiveCompare(token) == .orderedSame
                || folder.name.compare(token, options: .caseInsensitive) == .orderedSame
                || (matchContains && folder.name.lowercased().contains(lowered))
        }
    }
}

func applyNoteSelection(
    notes: [NotesNote],
    folders: [NotesFolder],
    folderFilters: [String],
    matchContains: Bool,
    includeSubfolders: Bool,
    includeDeleted: Bool,
    noteIds: [String]
) -> [NotesNote] {
    let tokens = parseListArgument(folderFilters)
    let wantsTrash = tokens.contains { isRecentlyDeletedFolderName($0) }
    let keepDeleted = includeDeleted || wantsTrash
    let folderIds = matchingFolderIds(
        filters: tokens,
        folders: folders,
        matchContains: matchContains,
        includeDescendants: includeSubfolders
    )
    return selectedNotes(
        from: notes,
        folderIds: folderIds,
        noteIds: Set(parseListArgument(noteIds)),
        includeDeleted: keepDeleted,
        selectAllTrash: wantsTrash
    )
}

/// Apply CLI/MCP note selection: listed note ids UNION notes in matching folders.
/// `includeDeleted` keeps Recently Deleted notes in the pool.
/// `selectAllTrash` is set when a filter is the Recently Deleted smart folder.
func selectedNotes(
    from notes: [NotesNote],
    folderIds: Set<String>,
    noteIds: Set<String>,
    includeDeleted: Bool,
    selectAllTrash: Bool
) -> [NotesNote] {
    if selectAllTrash && folderIds.isEmpty && noteIds.isEmpty {
        return notes.filter(\.isDeleted)
    }

    return notes.filter { note in
        if !includeDeleted && note.isDeleted { return false }

        if folderIds.isEmpty && noteIds.isEmpty {
            return true
        }
        if !noteIds.isEmpty && noteIds.contains(note.id) {
            return true
        }
        if note.isDeleted {
            if selectAllTrash { return true }
            return !folderIds.isEmpty && folderIds.contains(note.folderId)
        }
        return !folderIds.isEmpty && folderIds.contains(note.folderId)
    }
}

/// Directory and HTML-relative prefix for a note's attachments.
func attachmentExportLocation(
    sharedDump: Bool,
    outputRoot: URL,
    noteDirectory: URL,
    noteBaseName: String,
    filename: String
) -> (directory: URL, relativePath: String) {
    if !sharedDump {
        let dir = noteDirectory.appendingPathComponent("\(noteBaseName) (Attachments)")
        return (dir, "\(noteBaseName) (Attachments)/\(filename)")
    }

    let rootPath = outputRoot.standardizedFileURL.path
    let dirPath = noteDirectory.standardizedFileURL.path
    let relDir: String
    if dirPath == rootPath {
        relDir = ""
    } else if dirPath.hasPrefix(rootPath + "/") {
        relDir = String(dirPath.dropFirst(rootPath.count + 1))
    } else {
        relDir = ""
    }

    var attRel = "Attachments"
    if !relDir.isEmpty { attRel += "/\(relDir)" }
    attRel += "/\(noteBaseName)/\(filename)"

    let noteRel = relDir.isEmpty ? "note.ext" : "\(relDir)/note.ext"
    let href = relativePathFromSource(noteRel, toTarget: attRel)
    let dir = outputRoot.appendingPathComponent(
        attRel.split(separator: "/").dropLast().map(String.init).joined(separator: "/"),
        isDirectory: true
    )
    return (dir, href)
}

// MARK: - Attachment Export

/// One thing that happened while writing a note's attachments.
///
/// The exporter decides *what* happened and how it reads; each surface decides
/// where it goes and at what threshold. Returning a buffer rather than taking a
/// log closure is deliberate: the app's log is `@MainActor`, so a closure could
/// only reach it by hopping, which would reorder these lines against the note's
/// own. Draining the buffer at the call site preserves the original ordering.
struct AttachmentExportEvent {
    enum Severity { case info, warning }
    let severity: Severity
    let message: String
}

struct AttachmentExportResult {
    /// Attachment id, and each gallery child id, to a path relative to the note.
    var paths: [String: String] = [:]
    /// In the order they occurred.
    var events: [AttachmentExportEvent] = []
    /// Attachments that could not be written. Already counted on the tracker.
    var failures: Int = 0
}

/// Write a note's file attachments to disk and report where they landed.
///
/// The app, the CLI, the MCP server and the Shortcuts action all export
/// attachments through here. This used to exist as four separate copies, and
/// they drifted: the CLI's had no gallery expansion at all, so every gallery in
/// a CLI, MCP or Shortcuts export silently lost its images.
///
/// Nothing here is isolated, so the file I/O runs off the main thread even when
/// the app calls it.
func exportNoteAttachments(
    _ attachments: [NotesAttachment],
    toDirectory directory: URL,
    outputRoot: URL,
    noteBaseName: String,
    noteTitle: String,
    creationDate: Date,
    modificationDate: Date,
    sharedAttachmentsFolder: Bool,
    repository: NotesRepository,
    tracker: ExportProgressTracker? = nil
) async throws -> AttachmentExportResult {
    var result = AttachmentExportResult()

    let fileAttachments = filterFileAttachments(attachments)
    guard !fileAttachments.isEmpty else { return result }

    let attachmentsURL = attachmentExportLocation(
        sharedDump: sharedAttachmentsFolder,
        outputRoot: outputRoot,
        noteDirectory: directory,
        noteBaseName: noteBaseName,
        filename: "placeholder"
    ).directory
    try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

    // One place to resolve collisions, so a fix cannot reach only half the
    // branches again. The extension fallback matters: a base name with no
    // extension previously became "name (2)." with a trailing dot.
    var usedFilenames: [String: Int] = [:]
    func claim(_ base: String) -> String {
        guard let count = usedFilenames[base] else {
            usedFilenames[base] = 1
            return base
        }
        usedFilenames[base] = count + 1
        let (name, ext) = splitExportFilename(base)
        return "\(name) (\(count + 1)).\(ext.isEmpty ? "bin" : ext)"
    }

    func write(_ data: Data, as filename: String) throws -> String {
        let loc = attachmentExportLocation(
            sharedDump: sharedAttachmentsFolder,
            outputRoot: outputRoot,
            noteDirectory: directory,
            noteBaseName: noteBaseName,
            filename: filename
        )
        try FileManager.default.createDirectory(at: loc.directory, withIntermediateDirectories: true)
        let fileURL = loc.directory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        do {
            try setExportFileTimestamps(fileURL, creationDate: creationDate, modificationDate: modificationDate)
        } catch {
            // The bytes are on disk and correct; only the dates are wrong. That
            // is not worth failing the whole note over, which is what throwing
            // from here used to do.
            result.events.append(AttachmentExportEvent(
                severity: .warning,
                message: "Could not set timestamps on \(filename): \(error.localizedDescription)"
            ))
        }
        return loc.relativePath
    }

    for attachment in fileAttachments {
        try Task.checkCancellation()

        // A gallery is a container and holds no bytes of its own, so asking the
        // parser for its data fails by design; it has to be expanded.
        if attachment.typeUTI == "com.apple.notes.gallery" {
            do {
                let children = try await repository.fetchGalleryChildren(
                    galleryId: attachment.id, accountId: nil)
                for child in children {
                    let ext = child.filename.flatMap { fn in
                        fn.components(separatedBy: ".").last.flatMap { e in e.count <= 5 && e != fn ? e : nil }
                    } ?? child.uti.flatMap { NotesAttachment(id: child.id, typeUTI: $0, filename: nil).fileExtension }
                      ?? detectFileExtension(from: child.data)
                      ?? "jpg"
                    let filename = claim(child.filename ?? "\(child.id).\(ext)")
                    let relativePath = try write(child.data, as: filename)

                    result.paths[child.id] = relativePath
                    // The note's markup refers to the container, not the
                    // children, so point it at the first one.
                    if result.paths[attachment.id] == nil {
                        result.paths[attachment.id] = relativePath
                    }
                    result.events.append(AttachmentExportEvent(
                        severity: .info,
                        message: "✓ Exported attachment: \(filename) for note '\(noteTitle)'"
                    ))
                }
            } catch {
                result.failures += 1
                await tracker?.attachmentFailed()
                result.events.append(AttachmentExportEvent(
                    severity: .warning,
                    message: "✗ Gallery expansion failed for \(attachment.id): \(error.localizedDescription)"
                ))
                Logger.noteExport.warning(
                    "Gallery expansion failed for \(attachment.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            continue
        }

        do {
            let data = try await repository.fetchAttachment(id: attachment.id)

            let baseFilename: String
            if let filename = attachment.filename {
                baseFilename = filename
            } else if let fetched = await repository.fetchAttachmentFilename(id: attachment.id) {
                baseFilename = fetched
            } else {
                let ext = attachment.fileExtension ?? detectFileExtension(from: data) ?? "bin"
                baseFilename = "\(attachment.id).\(ext)"
            }

            let filename = claim(baseFilename)
            result.paths[attachment.id] = try write(data, as: filename)
            result.events.append(AttachmentExportEvent(
                severity: .info,
                message: "✓ Exported attachment: \(filename) for note '\(noteTitle)'"
            ))
        } catch {
            result.failures += 1
            await tracker?.attachmentFailed()
            let details = attachmentFailureDetails(attachment, noteTitle: noteTitle, error: error)
            result.events.append(AttachmentExportEvent(
                severity: .warning,
                message: "✗ Failed to export attachment - \(details)"
            ))
            Logger.noteExport.warning("Failed to export attachment: \(details, privacy: .public)")
            // Carry on; one bad attachment must not cost the others.
        }
    }

    do {
        try setExportFileTimestamps(attachmentsURL, creationDate: creationDate, modificationDate: modificationDate)
    } catch {
        result.events.append(AttachmentExportEvent(
            severity: .warning,
            message: "Could not set timestamps on the attachments folder: \(error.localizedDescription)"
        ))
    }

    return result
}

/// Everything known about a failed attachment, for the export log.
private func attachmentFailureDetails(
    _ attachment: NotesAttachment, noteTitle: String, error: Error
) -> String {
    var details = [
        "Attachment ID: \(attachment.id)",
        "Type: \(attachment.typeUTI)",
        "Note: '\(noteTitle)'"
    ]
    if let filename = attachment.filename { details.append("Filename: \(filename)") }
    details.append("Error: \(error.localizedDescription)")

    let nsError = error as NSError
    details.append("Domain: \(nsError.domain)")
    details.append("Code: \(nsError.code)")
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        details.append("Underlying: \(underlying.localizedDescription)")
    }
    return details.joined(separator: ", ")
}

/// Marker comment written into generated folder index.html files so a later
/// export can tell them apart from a note that happened to be titled "index".
let htmlFolderIndexMarker = "apple-notes-exporter-folder-index"

/// Write an `index.html` listing in each directory under `root` that contains
/// exported HTML notes or subfolders. Skips `* (Attachments)` directories.
func writeHTMLFolderIndexes(underRoot root: URL) throws {
    let fm = FileManager.default
    var dirs: [URL] = [root]
    let keys: [URLResourceKey] = [.isDirectoryKey]
    if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            if url.lastPathComponent.hasSuffix(" (Attachments)") || url.lastPathComponent == "Attachments" {
                enumerator.skipDescendants()
                continue
            }
            dirs.append(url)
        }
    }
    dirs.sort { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
    for dir in dirs {
        try writeHTMLFolderIndex(inFolder: dir)
    }
}

/// Write a single folder's `index.html` listing sibling HTML notes and subfolders.
func writeHTMLFolderIndex(inFolder folderURL: URL) throws {
    let fm = FileManager.default
    let contents = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

    var subfolders: [URL] = []
    var notes: [URL] = []
    for url in contents {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            if !url.lastPathComponent.hasSuffix(" (Attachments)") && url.lastPathComponent != "Attachments" {
                subfolders.append(url)
            }
            continue
        }
        if url.pathExtension.lowercased() == "html" && url.lastPathComponent.lowercased() != "index.html" {
            notes.append(url)
        }
    }

    let indexURL = folderURL.appendingPathComponent("index.html")
    if fm.fileExists(atPath: indexURL.path),
       let existing = try? String(contentsOf: indexURL, encoding: .utf8),
       !existing.contains(htmlFolderIndexMarker) {
        // A note was exported as index.html (older builds). Move it aside.
        let renamed = generateUniqueExportFilename(baseName: "index", extension: "html", inDirectory: folderURL)
        try fm.moveItem(at: indexURL, to: folderURL.appendingPathComponent(renamed))
        notes.append(folderURL.appendingPathComponent(renamed))
    }

    notes.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    subfolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    guard !notes.isEmpty || !subfolders.isEmpty else { return }

    func href(_ filename: String) -> String {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return encoded.htmlEscaped
    }

    var items: [String] = []
    for sub in subfolders {
        let name = sub.lastPathComponent.htmlEscaped
        items.append("    <li><a href=\"\(href(sub.lastPathComponent))/index.html\">\(name)/</a></li>")
    }
    for note in notes {
        let name = note.deletingPathExtension().lastPathComponent.htmlEscaped
        items.append("    <li><a href=\"\(href(note.lastPathComponent))\">\(name)</a></li>")
    }

    let folderName = folderURL.lastPathComponent.htmlEscaped
    let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>\(folderName)</title>
      <!-- \(htmlFolderIndexMarker) -->
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2em; line-height: 1.5; }
        h1 { font-size: 1.4em; }
        ul { padding-left: 1.2em; }
      </style>
    </head>
    <body>
      <h1>\(folderName)</h1>
      <ul>
    \(items.joined(separator: "\n"))
      </ul>
    </body>
    </html>
    """
    try html.write(to: indexURL, atomically: true, encoding: .utf8)
}

/// Filter attachments to only include exportable file attachments.
func filterFileAttachments(_ attachments: [NotesAttachment]) -> [NotesAttachment] {
    attachments.filter { attachment in
        !nonFileAttachmentPrefixes.contains { attachment.typeUTI.hasPrefix($0) }
    }
}

/// Create a copy of a NotesNote with a replaced htmlBody.
func noteWithHTML(_ note: NotesNote, html: String) -> NotesNote {
    NotesNote(
        id: note.id, title: note.title, plaintext: note.plaintext,
        htmlBody: html, creationDate: note.creationDate,
        modificationDate: note.modificationDate, folderId: note.folderId,
        accountId: note.accountId, attachments: note.attachments,
        identifier: note.identifier,
        isDeleted: note.isDeleted
    )
}

/// Generate text content for a note in the given format.
/// Render one note as text in the given format.
///
/// `concatenating` matters only for ENEX, where a Single File export needs the
/// bare `<note>` element so every note can share one `<en-export>` root.
/// `attachmentResources` carries file attachments that should travel inside the
/// .enex instead of being linked as sibling files.
func generateExportTextContent(
    for note: NotesNote,
    format: ExportFormat,
    folderName: String?,
    accountName: String?,
    concatenating: Bool = false,
    attachmentResources: [ENEXResource] = [],
    rtfFontFamily: String = "Helvetica",
    rtfFontSize: Double = 12,
    latexTemplate: String = LaTeXConfiguration.defaultTemplate
) -> String {
    switch format {
    case .html:     return note.htmlBody ?? ""
    case .txt:      return note.toPlainText()
    case .markdown: return note.toMarkdown()
    case .rtf:      return note.toRTF(fontFamily: rtfFontFamily, fontSize: rtfFontSize)
    case .tex:      return note.toLatex(template: latexTemplate)
    case .json:     return note.toJSON(folderName: folderName, accountName: accountName)
    case .jsonl:    return note.toJSONL(folderName: folderName, accountName: accountName)
    case .xml:
        return concatenating
            ? note.toXMLNoteElement(folderName: folderName, accountName: accountName)
            : note.toXML(folderName: folderName, accountName: accountName)
    case .csv:      return note.toCSV(folderName: folderName, accountName: accountName)
    case .opml:
        return concatenating ? note.toOPMLOutline() : note.toOPML()
    case .org:      return note.toOrg()
    case .rst:      return note.toRST()
    case .adoc:     return note.toAsciiDoc()
    case .enex:
        return concatenating
            ? note.toENEXNoteElement(attachmentResources: attachmentResources)
            : note.toENEX(attachmentResources: attachmentResources)
    case .pdf, .docx, .odt, .epub:
        fatalError("Format \(format.rawValue) should not use generateExportTextContent()")
    }
}
