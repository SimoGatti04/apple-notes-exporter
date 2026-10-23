//
//  NoteSelectorView.swift
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

import SwiftUI

struct NoteSelectorView: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    @EnvironmentObject var viewModel: NotesViewModel
    @Binding var showNoteSelectorView: Bool

    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedScope: NoteBrowserScope = .allNotes

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleNotes: [NotesNote] {
        // A non-empty query searches every account and folder so users never
        // need to navigate the hierarchy just to find a note by title.
        let candidates = normalizedQuery.isEmpty ? viewModel.notes(in: selectedScope) : viewModel.allNotes
        return NotesViewModel.filterNotes(candidates, matchingTitle: normalizedQuery)
    }

    private var visibleIDs: Set<String> { Set(visibleNotes.map(\.id)) }

    private var listSelection: Binding<Set<String>> {
        Binding(
            get: { viewModel.selectedNoteIDs.intersection(visibleIDs) },
            set: { selectedIDs in
                viewModel.updateVisibleSelection(selectedIDs, visibleIDs: visibleIDs)
                sharedState.update()
            }
        )
    }

    private var scopeHeading: String {
        normalizedQuery.isEmpty ? viewModel.scopeTitle(for: selectedScope) : "Search results · All accounts"
    }

    private var aggregateSelectionStatus: NoteSelectionStatus {
        viewModel.selectionStatus(for: viewModel.allNotes.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose notes")
                        .font(.title2.weight(.semibold))
                    Text("Search by title or browse an account. Select one note or use ⌘-click for multiple notes.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                notesPanel
                    .frame(minWidth: 430, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 12) {
                Label("\(viewModel.selectedCount) selected", systemImage: "checkmark.circle.fill")
                    .foregroundColor(viewModel.selectedCount == 0 ? .secondary : .accentColor)
                    .accessibilityLabel("\(viewModel.selectedCount) notes selected")
                Spacer()
                Button("Clear selection") {
                    viewModel.clearSelections()
                    sharedState.update()
                }
                .disabled(viewModel.selectedCount == 0)
                Button("Done") {
                    sharedState.update()
                    showNoteSelectorView = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .background(SwiftUI.Color(NSColor.windowBackgroundColor))
        .onAppear {
            sharedState.update()
            searchFieldFocused = true
        }
    }

    private var sidebar: some View {
        SwiftUI.List {
            Section {
                HStack(spacing: 6) {
                    BrowserScopeButton(
                        title: "All Notes",
                        icon: "tray.full",
                        count: viewModel.allNotes.count,
                        isSelected: selectedScope == .allNotes
                    ) { selectedScope = .allNotes }
                    SelectionMarkButton(
                        title: "all notes",
                        status: aggregateSelectionStatus,
                        isEnabled: !viewModel.allNotes.isEmpty
                    ) {
                        viewModel.toggleNotes(viewModel.allNotes.map(\.id))
                        sharedState.update()
                    }
                }
            }

            ForEach(viewModel.hierarchy.accounts) { accountNode in
                AccountBrowserSection(
                    accountNode: accountNode,
                    selectedScope: $selectedScope,
                    onSelectionChange: { sharedState.update() }
                )
            }
        }
        .listStyle(SidebarListStyle())
        .accessibilityLabel("Accounts and folders")
    }

    private var notesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search all notes by title", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .focused($searchFieldFocused)
                    .accessibilityLabel("Search all notes by title")
                    .accessibilityHint("Search covers every account and folder")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(SwiftUI.Color.secondary.opacity(0.08)))
            .padding([.horizontal, .top], 12)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeHeading)
                        .font(.headline)
                    Text("\(visibleNotes.count) note\(visibleNotes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(viewModel.selectionStatus(for: visibleNotes.map(\.id)) == .all ? "Deselect results" : "Select results") {
                    viewModel.toggleNotes(visibleNotes.map(\.id))
                    sharedState.update()
                }
                .disabled(visibleNotes.isEmpty || viewModel.loadingState.isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            noteListContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noteListContent: some View {
        switch viewModel.loadingState {
        case .idle:
            EmptyLibraryState(
                title: "Notes aren’t loaded yet",
                detail: "Load the local Notes library to search and select notes.",
                actionTitle: "Load Notes",
                action: { sharedState.reload() }
            )
        case .loading(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .error(let message):
            VStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if message.localizedCaseInsensitiveContains("Full Disk Access") {
                    Text("Enable Full Disk Access for Apple Notes Exporter in System Settings, then reload the library.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Try Again") { sharedState.reload() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        case .loaded:
            if viewModel.allNotes.isEmpty {
                EmptyLibraryState(
                    title: "No notes found",
                    detail: "Make sure Notes has synced to this Mac, then try reloading.",
                    actionTitle: "Reload Notes",
                    action: { sharedState.reload() }
                )
            } else if visibleNotes.isEmpty {
                EmptyLibraryState(
                    title: normalizedQuery.isEmpty ? "No notes in this location" : "No matching notes",
                    detail: normalizedQuery.isEmpty
                        ? "Choose another account or folder, or return to All Notes."
                        : "Try another title or clear the search field.",
                    actionTitle: normalizedQuery.isEmpty ? "Show All Notes" : "Clear Search",
                    action: {
                        if normalizedQuery.isEmpty { selectedScope = .allNotes }
                        else { searchText = "" }
                    }
                )
            } else {
                SwiftUI.List(selection: listSelection) {
                    ForEach(visibleNotes) { note in
                        NoteSelectionRow(note: note, location: viewModel.locationDescription(for: note))
                            .tag(note.id)
                    }
                }
                .listStyle(InsetListStyle())
                .accessibilityLabel("Notes")
            }
        }
    }
}

private struct AccountBrowserSection: View {
    @EnvironmentObject private var viewModel: NotesViewModel
    let accountNode: NotesHierarchy.AccountNode
    @Binding var selectedScope: NoteBrowserScope
    let onSelectionChange: () -> Void

    private var accountNotes: [NotesNote] { viewModel.notes(in: .account(accountNode.account.id)) }

    var body: some View {
        Section {
            ForEach(accountNode.folders) { folder in
                FolderBrowserRow(
                    folderNode: folder,
                    depth: 0,
                    selectedScope: $selectedScope,
                    onSelectionChange: onSelectionChange
                )
            }
        } header: {
            HStack(spacing: 6) {
                BrowserScopeButton(
                    title: accountNode.account.name,
                    icon: accountNode.account.icon,
                    count: accountNotes.count,
                    isSelected: selectedScope == .account(accountNode.account.id)
                ) { selectedScope = .account(accountNode.account.id) }
                SelectionMarkButton(
                    title: "all notes in \(accountNode.account.name)",
                    status: viewModel.selectionStatus(for: accountNotes.map(\.id)),
                    isEnabled: !accountNotes.isEmpty,
                    action: {
                        viewModel.toggleNotes(accountNotes.map(\.id))
                        onSelectionChange()
                    }
                )
            }
        }
    }
}

private struct FolderBrowserRow: View {
    @EnvironmentObject private var viewModel: NotesViewModel
    let folderNode: NotesHierarchy.FolderNode
    let depth: Int
    @Binding var selectedScope: NoteBrowserScope
    let onSelectionChange: () -> Void
    @State private var isExpanded = false

    private var folderNotes: [NotesNote] { viewModel.notes(in: .folder(folderNode.folder.id)) }
    private var hasChildren: Bool { !folderNode.subfolders.isEmpty }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                if hasChildren {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 16, height: 20)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(folderNode.folder.name)")
                } else {
                    Spacer().frame(width: 16)
                }

                BrowserScopeButton(
                    title: folderNode.folder.name,
                    icon: folderNode.folder.icon,
                    count: folderNotes.count,
                    isSelected: selectedScope == .folder(folderNode.folder.id)
                ) { selectedScope = .folder(folderNode.folder.id) }

                SelectionMarkButton(
                    title: "all notes in \(folderNode.folder.name)",
                    status: viewModel.selectionStatus(for: folderNode),
                    isEnabled: !folderNotes.isEmpty,
                    action: {
                        viewModel.toggleFolder(folderNode)
                        onSelectionChange()
                    }
                )
            }
            .padding(.leading, CGFloat(depth) * 12)

            if isExpanded {
                ForEach(folderNode.subfolders) { child in
                    FolderBrowserRow(
                        folderNode: child,
                        depth: depth + 1,
                        selectedScope: $selectedScope,
                        onSelectionChange: onSelectionChange
                    )
                }
            }
        }
    }
}

private struct BrowserScopeButton: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? SwiftUI.Color.accentColor.opacity(0.16) : .clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(.primary)
        .accessibilityLabel("\(title), \(count) notes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SelectionMarkButton: View {
    let title: String
    let status: NoteSelectionStatus
    var isEnabled: Bool = true
    let action: () -> Void

    private var symbol: String {
        switch status {
        case .none: return "square"
        case .partial: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    private var statusDescription: String {
        switch status {
        case .none: return "not selected"
        case .partial: return "partially selected"
        case .all: return "fully selected"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(BorderlessButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .foregroundColor(status == .none ? .secondary : .accentColor)
        .accessibilityLabel("Select or deselect \(title)")
        .accessibilityValue(isEnabled ? statusDescription : "No notes")
        .help(isEnabled ? "\(statusDescription.capitalized): \(title)" : "No notes in this location")
    }
}

private struct NoteSelectionRow: View {
    let note: NotesNote
    let location: String

    private var displayTitle: String { note.title.isEmpty ? "Untitled Note" : note.title }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: note.icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(location)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(note.modificationDate, style: .date)
                Text(note.modificationDate, style: .time)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle), \(location), modified \(note.modificationDate.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct EmptyLibraryState: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(actionTitle, action: action)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
