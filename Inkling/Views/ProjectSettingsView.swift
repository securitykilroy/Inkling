//
//  ProjectSettingsView.swift
//  Inkling
//
//  A sheet for editing project-level metadata (book title and author). Values
//  bind straight to the root Project managed object, so edits dirty the
//  document and flow through undo/autosave like any other change. Empty fields
//  fall back to derived defaults (the document name and the macOS account
//  name), shown here as placeholders.
//

import SwiftUI

struct ProjectSettingsView: View {
    @ObservedObject var project: Project
    let documentName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Settings")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Title", text: titleBinding, prompt: Text(derivedTitle))
                TextField("Subtitle", text: subtitleBinding, prompt: Text("Optional"))
                TextField("Author", text: authorBinding, prompt: Text(derivedAuthor))
            }
            .textFieldStyle(.roundedBorder)

            Text("Used for the title page, running heads, and page numbers when you print or export to PDF. The subtitle is optional and appears only on the title page. Leave blank to use the placeholders shown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var derivedTitle: String {
        ProjectMetadata.effectiveTitle(stored: nil, documentName: documentName)
    }

    private var derivedAuthor: String {
        ProjectMetadata.effectiveAuthor(stored: nil)
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { project.title ?? "" },
            set: { project.title = $0 }
        )
    }

    private var subtitleBinding: Binding<String> {
        Binding(
            get: { project.subtitle ?? "" },
            set: { project.subtitle = $0.isEmpty ? nil : $0 }
        )
    }

    private var authorBinding: Binding<String> {
        Binding(
            get: { project.author ?? "" },
            set: { project.author = $0.isEmpty ? nil : $0 }
        )
    }
}
