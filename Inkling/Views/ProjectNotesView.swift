//
//  ProjectNotesView.swift
//  Inkling
//
//  A project-wide scratchpad: one continuous rich-text note that isn't tied to
//  any chapter, shown in its own window (toggled from the Window menu) rather
//  than in the main split view. Distinct from per-chapter Notes (NotesPanel)
//  and from the Shelf (a list of discrete draggable scraps): this is a single
//  running place to drop thoughts about the whole project. Stored separately
//  from the manuscript in `Project.projectNotesData`, encoded like everything
//  else through RichTextCodec. Like NotesPanel, it reuses RichTextEditor with
//  no formatting toolbar — editable rich text, but deliberately plain in chrome.
//

import SwiftUI
import AppKit
import CoreData

/// The window that hosts `ProjectNotesView`. It refuses to become the app's
/// *main* window so that, while it's focused, AppKit keeps resolving nil-target
/// menu commands against the project window's `InklingDocument` rather than
/// dead-ending in this satellite window's (controller-less) responder chain.
/// It can still be key, so its editor accepts typing normally.
final class ProjectNotesWindow: NSWindow {
    override var canBecomeMain: Bool { false }
}

struct ProjectNotesView: View {
    @ObservedObject var project: Project

    var body: some View {
        RichTextEditor(data: bodyBinding, documentID: project.objectID, fontFamilyName: project.bodyFontFamily)
            .background(Color(nsColor: .textBackgroundColor))
    }

    private var bodyBinding: Binding<Data?> {
        Binding(get: { project.projectNotesData }, set: { project.projectNotesData = $0 })
    }
}
