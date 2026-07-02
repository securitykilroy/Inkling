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

    private let onSelectionChange: (NSManagedObjectID?) -> Void
    private let documentName: String

    init(context: NSManagedObjectContext,
         documentName: String = "",
         onSelectionChange: @escaping (NSManagedObjectID?) -> Void = { _ in }) {
        _viewModel = StateObject(wrappedValue: ProjectViewModel(context: context))
        _statistics = StateObject(wrappedValue: StatisticsViewModel(context: context))
        self.documentName = documentName
        self.onSelectionChange = onSelectionChange
    }

    var body: some View {
        NavigationSplitView {
            ChapterSidebar(viewModel: viewModel, statistics: statistics, navigator: navigator, selection: $selection, documentName: documentName)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let chapter = selection {
                ChapterDetailView(chapter: chapter, statistics: statistics, navigator: navigator)
            } else {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a chapter from the sidebar, or add one.")
                )
            }
        }
        .onChange(of: selection) { onSelectionChange(selection?.objectID) }
    }
}
