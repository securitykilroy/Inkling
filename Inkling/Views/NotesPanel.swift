//
//  NotesPanel.swift
//  Inkling
//
//  Per-chapter notes, shown alongside the main editor. Separate storage
//  (chapter.notesData) from the body, so notes never mix into the manuscript.
//  Reuses RichTextEditor without a formatting controller: notes are editable
//  rich text but intentionally have no formatting toolbar of their own.
//

import SwiftUI
import CoreData

struct NotesPanel: View {
    @Binding var data: Data?
    let documentID: NSManagedObjectID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)

            Divider()

            RichTextEditor(data: $data, documentID: documentID)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
