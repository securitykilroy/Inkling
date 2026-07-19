//
//  ProjectRootView.swift
//  Inkling
//
//  Root of a project window: a NavigationSplitView with the chapter sidebar on
//  the left and the selected chapter's detail on the right. Selection lives
//  here and is shared with the sidebar, so clicking a chapter navigates the
//  detail pane in-place within this single window.
//

import SwiftUI
import CoreData

struct ProjectRootView: View {
    @StateObject private var viewModel: ProjectViewModel
    @StateObject private var statistics: StatisticsViewModel
    @StateObject private var navigator = OutlineNavigator()
    @State private var selection: Chapter?
    @State private var didApplyInitialSelection = false

    private let onSelectionChange: (NSManagedObjectID?) -> Void
    private let onCaretChange: (Int) -> Void
    private let documentName: String
    /// Where the user last was in this document, if known. Used once, on first
    /// appear, to reopen at the same chapter and caret.
    private let initialPosition: LastEditPosition?

    init(context: NSManagedObjectContext,
         documentName: String = "",
         initialPosition: LastEditPosition? = nil,
         onSelectionChange: @escaping (NSManagedObjectID?) -> Void = { _ in },
         onCaretChange: @escaping (Int) -> Void = { _ in }) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(context: context))
        _statistics = StateObject(wrappedValue: StatisticsViewModel(context: context))
        self.documentName = documentName
        self.initialPosition = initialPosition
        self.onSelectionChange = onSelectionChange
        self.onCaretChange = onCaretChange
    }

    var body: some View {
        NavigationSplitView {
            ChapterSidebar(viewModel: viewModel, statistics: statistics, navigator: navigator, selection: $selection, documentName: documentName)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let chapter = selection {
                ChapterDetailView(chapter: chapter, project: viewModel.project, statistics: statistics, navigator: navigator, onCaretChange: onCaretChange)
            } else {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a chapter from the sidebar, or add one.")
                )
            }
        }
        .onChange(of: selection) { onSelectionChange(selection?.objectID) }
        .onAppear(perform: applyInitialSelection)
        .onDrop(of: InklingDocumentDrop.acceptedTypes, isTargeted: nil) { providers in
            InklingDocumentDrop.openFirstInklingDocument(from: providers)
        }
    }

    /// On first appear, reopen the document where the user last was: select the
    /// saved chapter and ask the navigator to place the caret there once its
    /// editor is laid out. With no saved position (a never-opened file, or the
    /// saved chapter was since deleted), fall back to the first chapter.
    private func applyInitialSelection() {
        guard !didApplyInitialSelection else { return }
        didApplyInitialSelection = true

        let chapters = viewModel.project.orderedChapters
        if let position = initialPosition,
           let chapter = chapters.first(where: { $0.id == position.chapterID }) {
            selection = chapter
            navigator.target = OutlineJumpTarget(
                chapterID: position.chapterID,
                range: NSRange(location: position.caret, length: 0)
            )
        } else {
            selection = chapters.first
        }
    }
}
