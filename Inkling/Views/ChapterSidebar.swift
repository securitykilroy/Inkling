//
//  ChapterSidebar.swift
//  Inkling
//
//  The sidebar listing the project's chapters in order. Selection is bound to
//  the parent so that clicking a chapter navigates the detail pane in-place —
//  no new windows, no separate documents. Supports add, delete (context menu
//  or Delete key), and drag-to-reorder.
//

import SwiftUI
import CoreData

struct ChapterSidebar: View {
    @ObservedObject var viewModel: ProjectViewModel
    @ObservedObject var statistics: StatisticsViewModel
    @ObservedObject var navigator: OutlineNavigator
    @Binding var selection: Chapter?
    var documentName: String = ""

    @EnvironmentObject private var commands: ProjectCommands
    @State private var expanded: Set<UUID> = []
    /// Chapters waiting on the delete confirmation.
    @State private var pendingDeletion: [Chapter] = []

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Chapter.sortIndex, ascending: true)],
        animation: .default
    )
    private var chapters: FetchedResults<Chapter>

    var body: some View {
        List(selection: $selection) {
            ForEach(chapters, id: \.self) { chapter in
                row(for: chapter)
                    .tag(chapter)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            delete([chapter])
                        }
                    }
            }
            .onMove { source, destination in
                viewModel.moveChapters(Array(chapters), from: source, to: destination)
            }
            .onDelete { offsets in
                delete(offsets.map { chapters[$0] })
            }
        }
        .navigationTitle(viewModel.project.title ?? "Inkling")
        .onAppear { statistics.primeAll() }
        // Importing a book adds chapters long after `onAppear`. Priming them
        // here — outside the view body — is what keeps the totals below from
        // having to compute anything during a render.
        .onChange(of: chapters.map(\.objectID)) { _, _ in
            statistics.primeMissing(for: Array(chapters))
        }
        // An undone or redone Replace All changes chapter bodies with no
        // editor reporting it, so the counts are refreshed here. Cheap when
        // nothing changed: `primeMissing` only recounts a body that differs.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { note in
            refreshStatistics(afterUndoBy: note.object)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { note in
            refreshStatistics(afterUndoBy: note.object)
        }
        .safeAreaInset(edge: .bottom) {
            let words = statistics.totalWords(for: Array(chapters))
            let pages = statistics.totalPages(for: Array(chapters))
            HStack(spacing: 6) {
                Text("Total").fontWeight(.semibold)
                Text("\(words) words")
                Text("·")
                Text("\(pages) \(pages == 1 ? "page" : "pages")")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .help("Total pages across all chapters, matching the editor; each chapter starts a new page.")
        }
        .onDeleteCommand {
            if let selected = selection { delete([selected]) }
        }
        // No `.keyboardShortcut` on these two: File ▸ New Chapter and
        // Edit ▸ Find ▸ Find & Replace in Project… already own ⇧⌘N and ⇧⌘F, and
        // both routes end at the same `ProjectCommands`. Declaring the same key
        // equivalent in the menu *and* on a toolbar button registers it twice,
        // which is how macOS ends up drawing a second, greyed-out copy of the
        // shortcut in the menu. The menu is the one owner; `.help` still shows
        // the key to the user.
        .toolbar {
            ToolbarItem {
                Button {
                    commands.requestNewChapter()
                } label: {
                    Label("Add Chapter", systemImage: "plus")
                }
                .help("Add Chapter (⇧⌘N)")
            }
            ToolbarItem {
                Button {
                    commands.presentFindReplace()
                } label: {
                    Label("Find & Replace", systemImage: "magnifyingglass")
                }
                .help("Find & Replace in Project (⇧⌘F)")
            }
            ToolbarItem {
                Button {
                    commands.presentSettings()
                } label: {
                    Label("Project Settings", systemImage: "gearshape")
                }
                .help("Project Settings (⌘,)")
            }
        }
        // Both the toolbar button and the Settings… / New Chapter menu items
        // route through `commands`, so each has a single behavior: one sheet
        // presentation, and one insert-and-select path shared with the button.
        .onChange(of: commands.newChapterRequests) {
            selection = viewModel.addChapter()
        }
        .sheet(isPresented: $commands.settingsPresented) {
            ProjectSettingsView(
                project: viewModel.project,
                statistics: statistics,
                documentName: documentName
            )
        }
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            )
        ) {
            Button("Delete", role: .destructive) {
                let toDelete = pendingDeletion
                pendingDeletion = []
                performDelete(toDelete)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(deletionMessage)
        }
        .overlay {
            if chapters.isEmpty {
                ContentUnavailableView(
                    "No Chapters",
                    systemImage: "book.closed",
                    description: Text("Click + to add your first chapter.")
                )
            }
        }
    }

    /// A chapter row, expandable into its outline (headings) when it has any.
    @ViewBuilder
    private func row(for chapter: Chapter) -> some View {
        ChapterOutlineRow(
            chapter: chapter,
            statistics: statistics,
            isExpanded: expansionBinding(for: chapter),
            onJump: { jump(to: chapter, heading: $0) }
        )
    }

    private func jump(to chapter: Chapter, heading: OutlineHeading) {
        selection = chapter
        if let id = chapter.id {
            navigator.target = OutlineJumpTarget(chapterID: id, range: heading.range)
        }
    }

    /// Expansion is keyed by the chapter's stable UUID, which survives the
    /// objectID changing on save. A chapter with no id (only reachable from a
    /// document written before `id` was populated) gets an inert binding rather
    /// than a freshly minted UUID: this is called on every render, so a new key
    /// each time both broke the toggle and grew `expanded` without bound.
    private func expansionBinding(for chapter: Chapter) -> Binding<Bool> {
        guard let id = chapter.id else { return .constant(false) }
        return Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func refreshStatistics(afterUndoBy sender: Any?) {
        guard let undoManager = viewModel.context.undoManager,
              (sender as AnyObject?) === undoManager
        else { return }
        statistics.primeMissing(for: Array(chapters))
    }

    /// Every delete route (Delete key, context menu, swipe) comes through
    /// here. A chapter with anything in it asks first; Undo also restores it,
    /// but an accidental keystroke shouldn't depend on noticing in time.
    private func delete(_ toDelete: [Chapter]) {
        guard !toDelete.isEmpty else { return }
        if ProjectViewModel.needsDeleteConfirmation(toDelete.map { ($0.bodyData, $0.notesData) }) {
            pendingDeletion = toDelete
        } else {
            performDelete(toDelete)
        }
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1 {
            let title = pendingDeletion[0].title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Chapter"
            return "Delete “\(title)”?"
        }
        return "Delete \(pendingDeletion.count) chapters?"
    }

    private var deletionMessage: String {
        let words = pendingDeletion.reduce(0) { $0 + statistics.wordCount(for: $1) }
        let single = pendingDeletion.count == 1
        let what = single ? "This chapter has" : "These chapters have"
        let contents = switch words {
        case 0: "images, sidebars or notes in \(single ? "it" : "them")"
        case 1: "1 word"
        default: "\(words.formatted()) words"
        }
        return "\(what) \(contents). You can get \(single ? "it" : "them") back with Edit ▸ Undo."
    }

    private func performDelete(_ toDelete: [Chapter]) {
        if let selected = selection, toDelete.contains(selected) {
            selection = nil
        }
        viewModel.deleteChapters(toDelete)
    }
}

/// Caches parsed headings as view state. Decoding RTF in `ChapterSidebar.body`
/// made every unrelated sidebar render reparse every chapter in the project.
private struct ChapterOutlineRow: View {
    @ObservedObject var chapter: Chapter
    @ObservedObject var statistics: StatisticsViewModel
    @Binding var isExpanded: Bool
    let onJump: (OutlineHeading) -> Void

    @State private var headings: [OutlineHeading] = []
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Group {
            if headings.isEmpty {
                ChapterRow(chapter: chapter, statistics: statistics)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(headings) { heading in
                        Button { onJump(heading) } label: {
                            Text(heading.text)
                                .lineLimit(1)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    ChapterRow(chapter: chapter, statistics: statistics)
                }
            }
        }
        .onAppear(perform: refreshHeadings)
        // The body changes on every keystroke in the chapter being edited, so
        // wait for a pause in typing rather than re-parsing the whole chapter
        // per character.
        .onChange(of: chapter.bodyData) { _, _ in scheduleHeadingsRefresh() }
        // Reordering the sidebar hands an existing row a *different* chapter
        // rather than building a new one, and neither hook above fires for
        // that: `onAppear` already happened, and the new chapter's bodyData is
        // simply a different value, not a change to the one being watched. The
        // cached headings then belong to whichever chapter the row showed
        // before — and since a chapter's first heading is usually its own
        // title, the row sprouts a neighbouring chapter's name beneath its own.
        .onChange(of: chapter) { _, _ in refreshHeadings() }
    }

    private func refreshHeadings() {
        refreshTask?.cancel()
        headings = ChapterOutline.headings(in: chapter.bodyData)
    }

    private func scheduleHeadingsRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            refreshHeadings()
        }
    }
}

/// A single row in the sidebar. Observes its chapter so the title updates live
/// while it is being edited in the detail pane.
private struct ChapterRow: View {
    @ObservedObject var chapter: Chapter
    @ObservedObject var statistics: StatisticsViewModel

    var body: some View {
        let title = chapter.title ?? ""
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Untitled Chapter" : title)
                Text("\(statistics.wordCount(for: chapter)) words")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
