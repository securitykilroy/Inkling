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
import CoreData

struct ProjectSettingsView: View {
    @ObservedObject var project: Project
    let documentName: String

    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: []) private var chapters: FetchedResults<Chapter>
    @FetchRequest(sortDescriptors: []) private var shelfEntries: FetchedResults<ShelfEntry>
    @State private var fontPanelController = FontPanelController()
    @AppStorage(PageStackView.defaultsKey) private var usePerPageEditor = false

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

            Divider()

            HStack {
                Text("Font")
                Spacer()
                Text(project.bodyFontFamily ?? "System Default")
                    .foregroundStyle(.secondary)
                if project.bodyFontFamily != nil {
                    Button("Use System Default") { applyFont(familyName: nil) }
                }
                Button("Choose Font…") { chooseFont() }
            }

            Text("Applies to the whole project — every chapter's body and notes, and everything on the Shelf, are restyled immediately, keeping their existing sizes and bold/italic formatting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Per-Page Editor (Experimental)", isOn: $usePerPageEditor)

            Text("Lays each page out in its own text container instead of faking page breaks in one long one. Experimental and text-only: images, sidebars, and callouts do not render yet, so keep it off for real writing. Reopen the project after changing this.")
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

    private func chooseFont() {
        let current = TextStyle.body.font(familyName: project.bodyFontFamily)
        fontPanelController.show(current: current) { newFont in
            applyFont(familyName: newFont.familyName)
        }
    }

    private func applyFont(familyName: String?) {
        project.bodyFontFamily = familyName
        let results = ProjectFontStyler.restyledChapters(
            chapters.compactMap { chapter in
                guard let id = chapter.id else { return nil }
                return FontStyledChapter(id: id, bodyData: chapter.bodyData, notesData: chapter.notesData)
            },
            familyName: familyName
        )
        for chapter in chapters {
            guard let id = chapter.id, let updated = results[id] else { continue }
            chapter.bodyData = updated.bodyData
            chapter.notesData = updated.notesData
        }

        for entry in shelfEntries {
            guard let attributed = RichTextCodec.decode(entry.bodyData) else { continue }
            entry.bodyData = RichTextCodec.encode(ProjectFontStyler.restyled(attributed, familyName: familyName))
        }
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

/// Bridges the shared `NSFontPanel`/`NSFontManager` target-action pattern to a
/// closure, so a SwiftUI button can drive it without adopting the responder
/// chain. `NSFontManager.shared.target` is a single global slot, so it's
/// re-pointed at this controller only while its panel session is active.
@MainActor
final class FontPanelController: NSObject {
    private var currentFont: NSFont = TextStyle.body.font
    private var onChange: ((NSFont) -> Void)?

    func show(current: NSFont, onChange: @escaping (NSFont) -> Void) {
        self.currentFont = current
        self.onChange = onChange
        let panel = NSFontPanel.shared
        panel.setPanelFont(current, isMultiple: false)
        NSFontManager.shared.target = self
        panel.orderFront(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let newFont = sender.convert(currentFont)
        currentFont = newFont
        onChange?(newFont)
    }
}
