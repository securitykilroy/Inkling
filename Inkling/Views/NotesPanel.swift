//
//  NotesPanel.swift
//  Inkling
//
//  Per-chapter notes, shown alongside the main editor (behind the Notes/Shelf
//  switcher in ChapterDetailView, which supplies the panel's header). Separate
//  storage (chapter.notesData) from the body, so notes never mix into the
//  manuscript. Reuses RichTextEditor without a formatting controller: notes
//  are editable rich text but intentionally have no formatting toolbar of
//  their own.
//

import SwiftUI
import CoreData

struct NotesPanel: View {
    @Binding var data: Data?
    let documentID: NSManagedObjectID
    var fontFamilyName: String? = nil
    /// Lets a project search jump select a match in the notes. Not a
    /// formatting controller: the notes still have no toolbar.
    var controller: RichTextController? = nil

    var body: some View {
        RichTextEditor(data: $data, documentID: documentID, controller: controller, fontFamilyName: fontFamilyName)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
