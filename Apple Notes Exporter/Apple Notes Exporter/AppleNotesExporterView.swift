//
//  AppleNotesExporterView.swift
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

import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Foundation

extension Binding {
    func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            }
        )
    }
}

struct AppleNotesExporterView: View {
    @Environment(\.openURL) var openURL
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var exportViewModel: ExportViewModel


    func setProgressWindow(_ state: Bool?) {
        self.sharedState.showProgressWindow = state ?? !self.sharedState.showProgressWindow
    }

    func triggerExportNotes() {
        // ** Validate
        // No notes selected
        if self.sharedState.selectedNotesCount == 0 {
            self.activeAlert = .noneSelected
            self.showAlert = true
            return
        }
        // A destination left over from a different container would fail late
        // and confusingly, so treat it as unset here.
        normalizeOutputPathForContainer()
        // No output folder or file chosen
        if self.outputPath == "" {
            self.activeAlert = .noOutput
            self.showAlert = true
            return
        }

        // Convert output format string to enum
        guard let format = ExportFormat(rawValue: outputFormat) else {
            return
        }
        guard let destinationURL = outputURL else {
            self.activeAlert = .noOutput
            self.showAlert = true
            return
        }

        let selectedNotes = notesViewModel.selectedNotes

        // Reset
        sharedState.update()

        // Show the export progress window
        setProgressWindow(true)

        // A single PDF is a flat, non-overwriting deliverable in the chosen
        // directory. Multi-note export keeps the established folder/archive
        // planner and produces one PDF per note rather than merging them.
        Task {
            if format == .pdf, selectedNotes.count == 1 {
                await exportViewModel.exportSingleNotePDF(selectedNotes[0], toDirectory: destinationURL)
            } else {
                await exportViewModel.exportNotes(
                    selectedNotes,
                    toDirectory: destinationURL,
                    format: format,
                    includeAttachments: exportViewModel.configurations.includeAttachments
                )
            }
        }
    }
    
    /**
     Select the output folder.
     */
    /// The four ways an export can be delivered, derived from the stored
    /// booleans so there is a single source of truth for "which container".
    enum OutputContainer: Equatable {
        case folder, zip, tar, singleFile
    }

    var currentOutputContainer: OutputContainer {
        if exportViewModel.configurations.zipOutput { return .zip }
        if exportViewModel.configurations.tarOutput { return .tar }
        if exportViewModel.configurations.concatenateOutput { return .singleFile }
        return .folder
    }

    private var isSingleNotePDFMode: Bool {
        selectedFormat == .pdf && notesViewModel.selectedCount == 1
    }

    /// Forget the chosen destination when the container changes.
    ///
    /// The containers do not mean the same thing by "output": the archives and
    /// a single file name a file, Folder names a directory. Carrying a path
    /// across a switch leaves a value the new mode has to reinterpret, so the
    /// user picks again with the right panel. This takes the new container as
    /// one value rather than a set of flags, so a destination added later
    /// cannot end up uncompared (TAR did, and switching to it kept the path).
    ///
    /// Call before mutating the configuration, since the old container is read
    /// back from it.
    func clearOutputPathIfContainerChanged(to newContainer: OutputContainer) {
        guard newContainer != currentOutputContainer else { return }
        outputPath = ""
        outputURL = nil
    }

    /// The alert shown when Export is pressed with no destination. Folder, an
    /// archive and a single file are three different things to have not chosen,
    /// so the wording follows the container rather than always saying "folder".
    var missingDestinationTitle: String {
        if isSingleNotePDFMode { return "No Output Folder Chosen" }
        if let archive = exportViewModel.configurations.archiveFormat {
            return "No \(archive.displayName) Location Chosen"
        }
        if exportViewModel.configurations.concatenateOutput {
            return "No Output File Chosen"
        }
        return "No Output Folder Chosen"
    }

    var missingDestinationMessage: String {
        if isSingleNotePDFMode {
            return "Choose the folder where the single PDF should be saved."
        }
        if let archive = exportViewModel.configurations.archiveFormat {
            return "Please choose where you would like the .\(archive.fileExtension) archive to be saved."
        }
        if exportViewModel.configurations.concatenateOutput {
            let ext = ExportFormat(rawValue: outputFormat)?.fileExtension ?? "file"
            return "Please choose where you would like the exported .\(ext) file to be saved."
        }
        return "Please choose the folder where you would like the exported notes to be saved."
    }

    /// Drop a stored destination the current container cannot use.
    ///
    /// outputPath is persisted, so clearing it only when the container changes
    /// is not enough: an archive path chosen in a previous session comes back
    /// on the next launch even if Folder is now selected, and the export then
    /// tries to create a directory where that .zip file already sits. A folder
    /// path under ZIP is fine, since the archive is named inside it.
    func normalizeOutputPathForContainer() {
        guard !outputPath.isEmpty else { return }
        if isSingleNotePDFMode {
            var isDirectory: ObjCBool = false
            let isExistingDirectory = FileManager.default.fileExists(
                atPath: outputPath,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            if !isExistingDirectory {
                outputPath = ""
                outputURL = nil
            }
            return
        }
        let ext = (outputPath as NSString).pathExtension.lowercased()
        // Only extensions this app produces are treated as a filename; a
        // directory legitimately called "my.notes" must not be discarded.
        let archiveExtensions = Set(ExportArchiveFormat.allCases.map(\.fileExtension))
        let ours = Set(ExportFormat.allCases.map(\.fileExtension)).union(archiveExtensions)

        let archive = exportViewModel.configurations.archiveFormat
        let isSingle = exportViewModel.configurations.concatenateOutput && archive == nil

        let stale: Bool
        if let archive {
            stale = ours.contains(ext) && ext != archive.fileExtension
        } else if isSingle {
            // The extension has to match the format being written, so
            // switching MD to TXT invalidates the stored name too.
            stale = ours.contains(ext) && ext != ExportFormat(rawValue: outputFormat)?.fileExtension
        } else {
            stale = ours.contains(ext)
        }
        guard stale else { return }
        outputPath = ""
        outputURL = nil
    }

    /// The filename and type to offer in a save panel, or nil when the
    /// container writes into a directory instead.
    func savePanelTarget() -> (name: String, type: UTType?)? {
        guard !isSingleNotePDFMode else { return nil }
        if let archive = exportViewModel.configurations.archiveFormat {
            let name = "\(ExportViewModel.zipRootName).\(archive.fileExtension)"
            // .tar has no first-class UTType constant; resolve it by extension
            // and leave the panel unfiltered if the system does not know it.
            return (name, archive == .zip ? .zip : UTType(filenameExtension: archive.fileExtension))
        }
        guard exportViewModel.configurations.concatenateOutput,
              let format = ExportFormat(rawValue: outputFormat) else { return nil }
        let ext = format.fileExtension
        // Not every export extension maps to a registered type (adoc, enex and
        // friends); leaving it unset just means the panel does not filter.
        return ("\(concatenatedFileBaseName).\(ext)", UTType(filenameExtension: ext))
    }

    func selectOutputFolder() {
        // One-note PDF always writes a uniquely named PDF into a directory,
        // regardless of advanced multi-note output-container preferences.
        // ZIP and Single File otherwise produce exactly one file, so the user
        // names that file rather than picking a directory to be filled.
        if let (suggestedName, contentType) = savePanelTarget() {
            let savePanel = NSSavePanel()
            if let contentType { savePanel.allowedContentTypes = [contentType] }
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = suggestedName
            savePanel.prompt = "Choose"
            savePanel.begin { response in
                if response == .OK, let exportURL = savePanel.url {
                    self.outputURL = exportURL
                    self.outputPath = exportURL.path
                }
            }
            return
        }

        let openPanel = NSOpenPanel()

        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.canChooseFiles = false
        openPanel.prompt = "Select Folder"

        // Use async begin() instead of blocking runModal() to avoid race conditions
        openPanel.begin { response in
            if response == .OK, let exportURL = openPanel.url {
                self.outputURL = exportURL
                self.outputPath = exportURL.path as String
            }
        }
    }
    
    private enum ActiveAlert {
        case noneSelected
        case noOutput
    }
    
    init(sharedState: AppleNotesExporterState) {
        self.sharedState = sharedState
    }
    
    // ** State
    // Data
    @ObservedObject private var sharedState: AppleNotesExporterState
    // Preferences (persisted across launches)
    @AppStorage("outputFormat") private var outputFormat = "PDF"
    @AppStorage("outputPath") private var outputPath: String = ""
    @State private var outputURL: URL? = nil
    // Show/hide different views.
    // Show license/permissions view on first launch OR when Full Disk Access has been
    // revoked since the last launch (e.g. user toggled it off in System Settings).
    @State private var showLicensePermissionsView: Bool = {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-exporter-main") {
            return false
        }
        let licenseAccepted = UserDefaults.standard.bool(forKey: "licenseAcceptedGPLv3")
        return !licenseAccepted || !hasNotesDatabaseAccess()
    }()
    @State private var showNoteSelectorView: Bool = false
    @State private var showFormatOptionsView: Bool = false
    @State private var showAdvancedOutputOptionsView: Bool = false
    @State private var showPDFPreview: Bool = false
    @State private var showMCPSetupView: Bool = false
    @State private var showAlert: Bool = false
    @State private var activeAlert: ActiveAlert = .noneSelected
    @State private var showSyncWarning: Bool = false
    @State private var now: Date = Date()
    private let syncTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    /// Formatted "last synced" string based on manifest in the selected output directory
    private var lastSyncedText: String {
        // Reference `now` so SwiftUI re-evaluates when the timer ticks
        _ = now
        guard let url = outputURL,
              let manifest = SyncManifest.load(from: url) else {
            return "Last synced never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced \(formatter.localizedString(for: manifest.lastSync, relativeTo: Date()))"
    }

    // Adjust spacing for macOS 15+ which has increased title font spacing
    private var titleBottomPadding: CGFloat {
        if #available(macOS 15.0, *) {
            return -5
        } else {
            return 0
        }
    }

    // Body of the ContentView
    private var selectedFormat: ExportFormat {
        ExportFormat(rawValue: outputFormat) ?? .pdf
    }

    private var notesCard: some View {
        Button { showNoteSelectorView = true } label: {
            HStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Scegli le note")
                        .font(.headline)
                    Text(notesViewModel.loadingState.isLoading
                         ? "Caricamento…"
                         : selectionCountDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let error = notesViewModel.loadingState.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 19)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SwiftUI.Color(nsColor: .controlBackgroundColor))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command])
        .disabled(notesViewModel.loadingState.isLoading)
        .accessibilityIdentifier("noteSelectionButton")
    }

    private var selectionCountDescription: String {
        let count = notesViewModel.selectedCount
        return count == 1 ? "1 nota selezionata" : "\(count) note selezionate"
    }

    private var formatSection: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(selectedFormat.rawValue)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .accessibilityLabel("Formato: \(selectedFormat.rawValue)")

            Spacer(minLength: 12)

            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button {
                        outputFormat = format.rawValue
                    } label: {
                        if format == selectedFormat {
                            Label(format.rawValue, systemImage: "checkmark")
                        } else {
                            Text(format.rawValue)
                        }
                    }
                }
            } label: {
                Label("Cambia formato", systemImage: "chevron.down")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("formatMenu")
        }
        .padding(.top, 2)
    }

    private var pdfChoiceSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aspetto")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    LargeSelectionButton(
                        title: "Originale",
                        subtitle: "Come in Note",
                        systemImage: "doc.text",
                        isSelected: exportViewModel.configurations.pdf.styleProfile == .faithful
                    ) {
                        exportViewModel.configurations.pdf.styleProfile = .faithful
                    }
                    .accessibilityIdentifier("pdfStyleFaithful")

                    LargeSelectionButton(
                        title: "Per studiare",
                        subtitle: "Più leggibile",
                        systemImage: "book",
                        isSelected: exportViewModel.configurations.pdf.styleProfile == .study
                    ) {
                        exportViewModel.configurations.pdf.styleProfile = .study
                    }
                    .accessibilityIdentifier("pdfStyleStudy")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Allegati")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    LargeSelectionButton(
                        title: "Con anteprima",
                        subtitle: nil,
                        systemImage: "photo",
                        isSelected: exportViewModel.configurations.pdf.attachmentMode == .previewAndEmbed
                    ) {
                        exportViewModel.configurations.pdf.attachmentMode = .previewAndEmbed
                    }
                    .accessibilityIdentifier("pdfAttachmentPreview")

                    LargeSelectionButton(
                        title: "Solo file",
                        subtitle: nil,
                        systemImage: "paperclip",
                        isSelected: exportViewModel.configurations.pdf.attachmentMode == .embedOnly
                    ) {
                        exportViewModel.configurations.pdf.attachmentMode = .embedOnly
                    }
                    .accessibilityIdentifier("pdfAttachmentOnly")
                }
            }
        }
    }

    private var destinationCard: some View {
        HStack(spacing: 14) {
            Image(systemName: destinationSystemImage)
                .font(.system(size: 21, weight: .medium))
                .frame(width: 30)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Destinazione")
                    .font(.headline)
                Text(destinationPathDescription)
                    .font(.subheadline)
                    .foregroundColor(outputPath.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: selectOutputFolder) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Cambia destinazione")
            .accessibilityIdentifier("chooseDestinationButton")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SwiftUI.Color(nsColor: .controlBackgroundColor))
        )
    }

    private var destinationSystemImage: String {
        if isSingleNotePDFMode { return "folder" }
        return exportViewModel.configurations.archiveFormat?.systemImage
            ?? (exportViewModel.configurations.concatenateOutput ? "doc.text" : "folder")
    }

    private var destinationPathDescription: String {
        outputPath.isEmpty ? "Scegli una cartella o un file" : outputPath
    }

    private var advancedOutputOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output container")
                .font(.subheadline.weight(.medium))
            HStack(spacing: selectionTileSpacing) {
                let canConcatenate = selectedFormat.supportsConcatenation
                let isZip = exportViewModel.configurations.zipOutput
                let isTar = exportViewModel.configurations.tarOutput && !isZip
                let isArchive = isZip || isTar
                let isSingle = exportViewModel.configurations.concatenateOutput && !isArchive

                OutputContainerButton(title: "Folder", icon: "folder", isSelected: !isArchive && !isSingle) {
                    clearOutputPathIfContainerChanged(to: .folder)
                    exportViewModel.configurations.zipOutput = false
                    exportViewModel.configurations.tarOutput = false
                    exportViewModel.configurations.concatenateOutput = false
                    exportViewModel.saveConfigurations()
                }
                OutputContainerButton(title: "ZIP", icon: "doc.zipper", isSelected: isZip) {
                    clearOutputPathIfContainerChanged(to: .zip)
                    exportViewModel.configurations.zipOutput = true
                    exportViewModel.configurations.tarOutput = false
                    exportViewModel.configurations.concatenateOutput = false
                    exportViewModel.configurations.incrementalSync = false
                    showSyncWarning = false
                    exportViewModel.saveConfigurations()
                }
                OutputContainerButton(title: "TAR", icon: "shippingbox", isSelected: isTar) {
                    clearOutputPathIfContainerChanged(to: .tar)
                    exportViewModel.configurations.tarOutput = true
                    exportViewModel.configurations.zipOutput = false
                    exportViewModel.configurations.concatenateOutput = false
                    exportViewModel.configurations.incrementalSync = false
                    showSyncWarning = false
                    exportViewModel.saveConfigurations()
                }
                OutputContainerButton(
                    title: "Single File",
                    icon: "doc.text",
                    isSelected: isSingle,
                    isEnabled: canConcatenate,
                    disabledHelp: "\(selectedFormat.rawValue) is a packaged format, so notes cannot be joined into one file."
                ) {
                    clearOutputPathIfContainerChanged(to: .singleFile)
                    exportViewModel.configurations.concatenateOutput = true
                    exportViewModel.configurations.zipOutput = false
                    exportViewModel.configurations.tarOutput = false
                    exportViewModel.configurations.incrementalSync = false
                    showSyncWarning = false
                    exportViewModel.saveConfigurations()
                }
            }

            Divider()
            OutputOptionRow(
                title: "Include attachments",
                help: "Export images, PDFs, drawings, and other files attached to each note.",
                isOn: $exportViewModel.configurations.includeAttachments
            )
            OutputOptionRow(
                title: "Shared Attachments folder",
                help: "Collect attachments in one top-level folder instead of beside each note.",
                isOn: $exportViewModel.configurations.sharedAttachmentsFolder,
                isEnabled: exportViewModel.configurations.includeAttachments
            )

            let isZip = exportViewModel.configurations.zipOutput || exportViewModel.configurations.tarOutput
            let isSingle = exportViewModel.configurations.concatenateOutput && !isZip
            if !isSingle {
                OutputOptionRow(
                    title: "Add date to filename",
                    help: "Prefix each exported file with the note's creation date.",
                    isOn: $exportViewModel.configurations.addDateToFilename
                ) {
                    Picker("Date format", selection: $exportViewModel.configurations.filenameDateFormat) {
                        ForEach(FilenameDateFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .frame(width: 190)
                    .disabled(!exportViewModel.configurations.addDateToFilename)
                }
            }
            if !isSingle && !isZip {
                OutputOptionRow(
                    title: "Incremental sync",
                    help: "Update changed notes in this folder and remove notes deleted from Apple Notes.",
                    isOn: $exportViewModel.configurations.incrementalSync
                )
            }
        }
        .padding(.top, 8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("Apple Notes Exporter")
                        .font(.title2.weight(.semibold))
                    Spacer()

                    Menu {
                        if selectedFormat.hasOptionsSheet {
                            Button("Preferenze formato…") { showFormatOptionsView = true }
                        }
                        Button("Opzioni avanzate…") { showAdvancedOutputOptionsView = true }
                        Divider()
                        Button("Configurazione MCP…") { showMCPSetupView = true }
                        Button("Permessi e licenza…") { showLicensePermissionsView = true }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Impostazioni")
                    .accessibilityIdentifier("settingsMenu")
                }

                notesCard

                Divider()

                formatSection
                if selectedFormat == .pdf {
                    pdfChoiceSections
                }

                destinationCard

                if showSyncWarning {
                    Label(
                        "La sincronizzazione aggiorna i file già presenti. \(lastSyncedText)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button {
                        showPDFPreview = true
                    } label: {
                        Label("Anteprima", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(
                        selectedFormat != .pdf
                            || notesViewModel.selectedCount == 0
                            || notesViewModel.loadingState.isLoading
                    )
                    .accessibilityIdentifier("previewButton")

                    Button(action: triggerExportNotes) {
                        Label(
                            exportButtonTitle,
                            systemImage: "square.and.arrow.down"
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        notesViewModel.selectedCount == 0
                            || outputPath.isEmpty
                            || notesViewModel.loadingState.isLoading
                    )
                    .accessibilityIdentifier("exportButton")
                }

                if notesViewModel.selectedCount == 0 || outputPath.isEmpty {
                    Text(notesViewModel.selectedCount == 0
                         ? "Scegli almeno una nota per continuare."
                         : "Scegli una destinazione per continuare.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 540, idealWidth: 660, minHeight: 620, idealHeight: 720)
        .onAppear {
            showSyncWarning = exportViewModel.configurations.incrementalSync
            normalizeOutputPathForContainer()
            if !outputPath.isEmpty {
                outputURL = URL(fileURLWithPath: outputPath)
            }
            if ExportFormat(rawValue: outputFormat) == nil { outputFormat = "PDF" }
            if sharedState.licenseAccepted && !showLicensePermissionsView {
                sharedState.reload()
            }
        }
        .onChange(of: notesViewModel.selectedCount) { _ in
            normalizeOutputPathForContainer()
            sharedState.update()
        }
        .onReceive(syncTimer) { now = $0 }
        .onChange(of: sharedState.triggerSelectNotes) { triggered in
            if triggered {
                sharedState.triggerSelectNotes = false
                showNoteSelectorView = true
            }
        }
        .onChange(of: sharedState.triggerChooseFolder) { triggered in
            if triggered {
                sharedState.triggerChooseFolder = false
                selectOutputFolder()
            }
        }
        .onChange(of: sharedState.triggerExport) { triggered in
            if triggered {
                sharedState.triggerExport = false
                triggerExportNotes()
            }
        }
        .onChange(of: sharedState.triggerMCPSetup) { trigger in
            if trigger {
                showMCPSetupView = true
                sharedState.triggerMCPSetup = false
            }
        }
        .onChange(of: outputFormat) { newFormat in
            let supportsConcat = ExportFormat(rawValue: newFormat)?.supportsConcatenation ?? false
            normalizeOutputPathForContainer()
            if !supportsConcat && exportViewModel.configurations.concatenateOutput {
                exportViewModel.configurations.concatenateOutput = false
                exportViewModel.saveConfigurations()
            }
        }
        .onChange(of: exportViewModel.configurations.addDateToFilename) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.filenameDateFormat) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.includeAttachments) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.styleProfile) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.attachmentMode) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.htmlConfiguration.fontFamily) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.htmlConfiguration.fontSizePoints) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.htmlConfiguration.marginSize) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.htmlConfiguration.marginUnit) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.pdf.pageSize) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.sharedAttachmentsFolder) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.concatenateOutput) { _ in exportViewModel.saveConfigurations() }
        .onChange(of: exportViewModel.configurations.incrementalSync) { _ in
            exportViewModel.saveConfigurations()
            showSyncWarning = exportViewModel.configurations.incrementalSync
        }
        .sheet(isPresented: $sharedState.showProgressWindow) {
            ExportView(sharedState: sharedState)
                .frame(width: 400)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(true)
                .onAppear {
                    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        event.keyCode == 53 ? nil : event
                    }
                }
        }
        .sheet(isPresented: $showNoteSelectorView) {
            NoteSelectorView(sharedState: sharedState, showNoteSelectorView: $showNoteSelectorView)
                .frame(width: 920, height: 620)
        }
        .sheet(isPresented: $showMCPSetupView) {
            MCPSetupView(showMCPSetupView: $showMCPSetupView)
        }
        .sheet(isPresented: $showFormatOptionsView) {
            if let format = ExportFormat(rawValue: outputFormat) {
                FormatOptionsView(showOptionsView: $showFormatOptionsView, format: format)
            }
        }
        .sheet(isPresented: $showAdvancedOutputOptionsView) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Opzioni avanzate")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Fine") {
                        exportViewModel.saveConfigurations()
                        showAdvancedOutputOptionsView = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Divider()
                ScrollView {
                    advancedOutputOptions
                        .padding(.bottom, 18)
                }
            }
            .padding(20)
            .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 680)
        }
        .sheet(isPresented: $showPDFPreview) {
            PDFPreviewSheet(
                notes: notesViewModel.selectedNotes,
                exportViewModel: exportViewModel,
                isPresented: $showPDFPreview
            )
            .frame(minWidth: 850, idealWidth: 1120, minHeight: 620, idealHeight: 780)
        }
        .sheet(isPresented: $showLicensePermissionsView) {
            LicensePermissionsView(
                sharedState: sharedState,
                showLicensePermissionsView: $showLicensePermissionsView
            )
        }
        .alert(isPresented: $showAlert) {
            switch activeAlert {
            case .noneSelected:
                Alert(
                    title: Text("No Notes Selected for Export"),
                    message: Text("Please select at least one note that you would like to export."),
                    dismissButton: .default(Text("OK"))
                )
            case .noOutput:
                Alert(
                    title: Text(missingDestinationTitle),
                    message: Text(missingDestinationMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var exportButtonTitle: String {
        let count = notesViewModel.selectedCount
        if exportViewModel.configurations.incrementalSync { return "Sincronizza" }
        return count == 1 ? "Esporta 1 nota" : "Esporta \(count) note"
    }

}


@MainActor
private struct PDFPreviewSheet: View {
    @ObservedObject private var exportViewModel: ExportViewModel
    @StateObject private var previewModel: PDFPreviewViewModel
    @State private var selectedNoteID: String?
    @Binding private var isPresented: Bool

    let notes: [NotesNote]

    init(notes: [NotesNote], exportViewModel: ExportViewModel, isPresented: Binding<Bool>) {
        self.notes = notes
        self.exportViewModel = exportViewModel
        _isPresented = isPresented
        _selectedNoteID = State(initialValue: notes.first?.id)
        _previewModel = StateObject(wrappedValue: PDFPreviewViewModel(exportViewModel: exportViewModel))
    }

    private var settingsKey: PDFPreviewSettingsKey {
        PDFPreviewSettingsKey(configuration: exportViewModel.configurations.pdf)
    }

    private var selectedNote: NotesNote? {
        notes.first(where: { $0.id == selectedNoteID }) ?? notes.first
    }

    private var noteIDs: [String] { notes.map(\.id) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Preferenze")
                        .font(.title2.weight(.semibold))

                    Picker("Aspetto", selection: $exportViewModel.configurations.pdf.styleProfile) {
                        Text("Originale").tag(PDFStyleProfile.faithful)
                        Text("Per studiare").tag(PDFStyleProfile.study)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("previewStylePicker")

                    Picker("Allegati", selection: $exportViewModel.configurations.pdf.attachmentMode) {
                        Text("Con anteprima").tag(PDFAttachmentMode.previewAndEmbed)
                        Text("Solo file").tag(PDFAttachmentMode.embedOnly)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("previewAttachmentPicker")

                    Divider()

                    Picker("Carattere", selection: $exportViewModel.configurations.pdf.htmlConfiguration.fontFamily) {
                        ForEach(HTMLConfiguration.FontFamily.allCases, id: \.self) { family in
                            Text(family.rawValue).tag(family)
                        }
                    }

                    Stepper(
                        value: $exportViewModel.configurations.pdf.htmlConfiguration.fontSizePoints,
                        in: 8...32,
                        step: 1
                    ) {
                        HStack {
                            Text("Dimensione")
                            Spacer(minLength: 8)
                            Text("\(Int(exportViewModel.configurations.pdf.htmlConfiguration.fontSizePoints)) pt")
                                .foregroundColor(.secondary)
                        }
                    }

                    Picker("Margini", selection: $exportViewModel.configurations.pdf.htmlConfiguration.marginUnit) {
                        ForEach(HTMLConfiguration.MarginUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }

                    Stepper(
                        value: $exportViewModel.configurations.pdf.htmlConfiguration.marginSize,
                        in: 0...96,
                        step: 2
                    ) {
                        HStack {
                            Text("Ampiezza")
                            Spacer(minLength: 8)
                            Text("\(Int(exportViewModel.configurations.pdf.htmlConfiguration.marginSize)) \(exportViewModel.configurations.pdf.htmlConfiguration.marginUnit.displayName)")
                                .foregroundColor(.secondary)
                        }
                    }

                    Picker("Formato pagina", selection: $exportViewModel.configurations.pdf.pageSize) {
                        ForEach(PDFConfiguration.PageSize.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 340)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Anteprima")
                        .font(.title2.weight(.semibold))

                    if notes.count > 1 {
                        Picker("Nota", selection: $selectedNoteID) {
                            ForEach(notes, id: \.id) { note in
                                Text(note.title).tag(Optional(note.id))
                            }
                        }
                        .frame(maxWidth: 280)
                    }

                    Spacer(minLength: 8)

                    Label(
                        previewModel.isUpdating ? "Aggiornamento…" : "Aggiornamento automatico",
                        systemImage: previewModel.isUpdating ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                    )
                    .accessibilityIdentifier("pdfPreviewStatus")
                    .font(.subheadline)
                    .foregroundColor(previewModel.isUpdating ? .secondary : .green)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider()

                Group {
                    if notes.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("Nessuna nota selezionata")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let document = previewModel.document {
                        PDFPreviewDocumentView(document: document)
                            .id(selectedNote?.id)
                            .accessibilityIdentifier("pdfPreviewDocument")
                            .padding(18)
                    } else if let error = previewModel.errorMessage {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.orange)
                            Text("Anteprima non disponibile")
                                .font(.headline)
                            Text(error)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Preparazione dell’anteprima…")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SwiftUI.Color(nsColor: .underPageBackgroundColor))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button("Chiudi") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .padding(18)
        }
        .onAppear { refreshPreview() }
        .onChange(of: selectedNoteID) { _ in refreshPreview() }
        .onChange(of: noteIDs) { newIDs in
            if !newIDs.contains(selectedNoteID ?? "") {
                selectedNoteID = newIDs.first
            }
            refreshPreview()
        }
        .onChange(of: settingsKey) { _ in refreshPreview() }
        .onDisappear { previewModel.cancel() }
    }

    private func refreshPreview() {
        previewModel.schedule(for: selectedNote)
    }
}

@MainActor
private final class PDFPreviewViewModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let exportViewModel: ExportViewModel
    private var generationTask: Task<Void, Never>?
    private var currentRequestID = UUID()

    init(exportViewModel: ExportViewModel) {
        self.exportViewModel = exportViewModel
    }

    func schedule(for note: NotesNote?) {
        generationTask?.cancel()
        let requestID = UUID()
        currentRequestID = requestID
        errorMessage = nil

        guard let note else {
            isUpdating = false
            document = nil
            return
        }

        isUpdating = true
        generationTask = Task { [weak self, exportViewModel] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                try Task.checkCancellation()
                let data = try await exportViewModel.generatePDFPreviewData(for: note)
                try Task.checkCancellation()
                guard let self, self.currentRequestID == requestID else { return }
                guard let document = PDFDocument(data: data) else {
                    throw ExportError.invalidGeneratedPDF
                }
                self.document = document
                self.errorMessage = nil
                self.isUpdating = false
            } catch is CancellationError {
                guard let self, self.currentRequestID == requestID else { return }
                self.isUpdating = false
            } catch {
                guard let self, self.currentRequestID == requestID else { return }
                self.errorMessage = error.localizedDescription
                self.isUpdating = false
            }
        }
    }

    func cancel() {
        currentRequestID = UUID()
        generationTask?.cancel()
        generationTask = nil
        isUpdating = false
    }
}

private struct PDFPreviewSettingsKey: Equatable {
    let fontFamily: String
    let fontSizePoints: Double
    let marginSize: Double
    let marginUnit: String
    let pageSize: String
    let styleProfile: String
    let attachmentMode: String

    init(configuration: PDFConfiguration) {
        fontFamily = configuration.htmlConfiguration.fontFamily.rawValue
        fontSizePoints = configuration.htmlConfiguration.fontSizePoints
        marginSize = configuration.htmlConfiguration.marginSize
        marginUnit = configuration.htmlConfiguration.marginUnit.rawValue
        pageSize = configuration.pageSize.rawValue
        styleProfile = configuration.styleProfile.rawValue
        attachmentMode = configuration.attachmentMode.rawValue
    }
}

private struct PDFPreviewDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }

        let currentPageIndex = view.document.flatMap { oldDocument in
            view.currentPage.map(oldDocument.index(for:))
        }
        let previousScale = view.scaleFactor
        let shouldPreserveScale = view.document != nil && previousScale > 0

        view.document = document
        view.autoScales = true
        DispatchQueue.main.async {
            view.layoutSubtreeIfNeeded()
            if let currentPageIndex, document.pageCount > 0 {
                let safePageIndex = min(currentPageIndex, document.pageCount - 1)
                if let page = document.page(at: safePageIndex) { view.go(to: page) }
            }
            if shouldPreserveScale { view.scaleFactor = previousScale }
        }
    }
}

private struct LargeSelectionButton: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .frame(height: 26)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 92 : 112)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SwiftUI.Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary.opacity(0.28),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selezionato" : "Non selezionato")
    }
}

// MARK: - Pointer Cursor for Links

extension View {
    /// Show a pointing hand cursor on hover (for hyperlinks)
    func pointerOnHover() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct BorderedProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .foregroundColor(.white)
            .background(configuration.isPressed ? SwiftUI.Color.blue.opacity(0.8) : SwiftUI.Color.blue)
            .cornerRadius(6)
            
    }
}


/// Box the output path icon sits in, wide enough for the widest of the three
/// glyphs so swapping between them does not move the text beside it.
private let destinationIconSize = CGSize(width: 20, height: 18)

private extension View {
    /// Isolate this view's geometry from animations owned by its ancestors, so
    /// a layout change elsewhere cannot animate this view into a new position.
    ///
    /// geometryGroup() is the real API for this; transformEffect(.identity) is
    /// the long-standing stand-in for it before macOS 14, which this app still
    /// deploys to.
    @ViewBuilder
    func isolatedGeometry() -> some View {
        if #available(macOS 14.0, *) {
            geometryGroup()
        } else {
            transformEffect(.identity)
        }
    }
}

// MARK: - Step 3 option rows

/// Rows in Step 3 share a fixed height. Without it the row carrying the date
/// picker is taller than the plain checkbox rows, so the gaps between the
/// checkboxes read as uneven even though the stack spacing is uniform.
// Row pitch is height + spacing. The date picker is the tallest thing in any
// row at roughly 22pt, so the height stays above that to avoid clipping it and
// the gap is taken out of the spacing instead. Together these halve the visible
// gap between checkboxes compared with the original 26 + 4.
/// Gap between tiles in the Step 2 format grid and the Step 3 container
/// buttons, which are meant to read as the same kind of control.
let selectionTileSpacing: CGFloat = 6

private let outputOptionRowHeight: CGFloat = 24
private let outputOptionRowSpacing: CGFloat = 0

/// A "?" affordance carrying a tooltip. Uses `.help`, so it appears on hover
/// and is also exposed to VoiceOver rather than being purely decorative.
private struct OptionHelpTip: View {
    let text: String

    @State private var isShowingHelp = false

    var body: some View {
        Button {
            isShowingHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .contentShape(Rectangle())
        }
        .buttonStyle(HelpTipButtonStyle(isActive: isShowingHelp))
        .popover(isPresented: $isShowingHelp, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
        // A Button is a real control, so .help also gives the hover tooltip.
        .help(text)
        .accessibilityLabel(Text(text))
    }
}

/// Press feedback for the help icons. A plain button style leaves them inert,
/// so they look like decoration rather than something you can click.
private struct HelpTipButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(
                configuration.isPressed || isActive ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One checkbox row: toggle, help tip, and optional trailing controls.
private struct OutputOptionRow<Trailing: View>: View {
    let title: String
    let help: String
    @Binding var isOn: Bool
    var isEnabled: Bool
    let trailing: () -> Trailing

    init(
        title: String,
        help: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.help = help
        self._isOn = isOn
        self.isEnabled = isEnabled
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: $isOn)
                .disabled(!isEnabled)
            OptionHelpTip(text: help)
                .opacity(isEnabled ? 1 : 0.4)
            Spacer()
            trailing()
        }
        .frame(height: outputOptionRowHeight)
    }
}

extension OutputOptionRow where Trailing == EmptyView {
    init(title: String, help: String, isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.init(title: title, help: help, isOn: isOn, isEnabled: isEnabled) { EmptyView() }
    }
}


/// Folder vs ZIP selector above the output path. Deliberately mirrors the
/// format tiles in Step 2 (same icon size, padding, corner radius and selected
/// treatment) so the two controls read as the same kind of choice, but with
/// two buttons they each take half the width instead of being narrow.
private struct OutputContainerButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var isEnabled: Bool = true
    var disabledHelp: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(isSelected ? .white : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? SwiftUI.Color.accentColor : SwiftUI.Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? SwiftUI.Color.clear : SwiftUI.Color.gray.opacity(0.3), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.4)
        .help(isEnabled ? "" : (disabledHelp ?? ""))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        // Without this the cross-fade above also animates the button's
        // position: selecting a container changes the layout below it, and the
        // animation transaction picks that movement up. Isolating the geometry
        // keeps the fade and drops the slide.
        .isolatedGeometry()
    }
}
