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

    @State private var expanded: Set<UUID> = []
    @State private var showingSettings = false

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
            .help("Estimated at \(TextStatistics.wordsPerPage) words per page; each chapter starts a new page.")
        }
        .onDeleteCommand {
            if let selected = selection { delete([selected]) }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    selection = viewModel.addChapter()
                } label: {
                    Label("Add Chapter", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Add Chapter (⇧⌘N)")
            }
            ToolbarItem {
                Button {
                    showingSettings = true
                } label: {
                    Label("Project Settings", systemImage: "gearshape")
                }
                .help("Project Settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            ProjectSettingsView(project: viewModel.project, documentName: documentName)
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
        let headings = ChapterOutline.headings(in: chapter.bodyData)
        if headings.isEmpty {
            ChapterRow(chapter: chapter, statistics: statistics)
        } else {
            DisclosureGroup(isExpanded: expansionBinding(for: chapter)) {
                ForEach(headings) { heading in
                    Button {
                        jump(to: chapter, heading: heading)
                    } label: {
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

    private func jump(to chapter: Chapter, heading: OutlineHeading) {
        selection = chapter
        if let id = chapter.id {
            navigator.target = OutlineJumpTarget(chapterID: id, range: heading.range)
        }
    }

    private func expansionBinding(for chapter: Chapter) -> Binding<Bool> {
        let id = chapter.id ?? UUID()
        return Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func delete(_ toDelete: [Chapter]) {
        if let selected = selection, toDelete.contains(selected) {
            selection = nil
        }
        viewModel.deleteChapters(toDelete)
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
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Untitled Chapter" : title)
                Text("\(statistics.wordCount(for: chapter)) words")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
