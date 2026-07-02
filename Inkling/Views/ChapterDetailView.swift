//
//  ChapterDetailView.swift
//  Inkling
//
//  Detail pane for the selected chapter: an editable title, a formatting
//  toolbar with a notes toggle, the rich-text body editor, and an optional
//  notes panel alongside it (in a resizable split). The notes-visibility
//  preference is shared across windows via @AppStorage.
//

import SwiftUI
import CoreData

struct ChapterDetailView: View {
    @ObservedObject var chapter: Chapter
    @ObservedObject var statistics: StatisticsViewModel
    @ObservedObject var navigator: OutlineNavigator
    @StateObject private var controller = RichTextController()
    @State private var laidOutPageCount = 1
    @AppStorage("showNotesPanel") private var showNotes = true

    var body: some View {
        VStack(spacing: 0) {
            TextField("Chapter Title", text: titleBinding)
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            HStack(spacing: 12) {
                FormatToolbar(controller: controller)
                Spacer()
                Button { showNotes.toggle() } label: {
                    Image(systemName: "note.text")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showNotes ? Color.accentColor : Color.secondary)
                .help(showNotes ? "Hide Notes" : "Show Notes")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            HSplitView {
                RichTextEditor(
                    data: bodyBinding,
                    documentID: chapter.objectID,
                    controller: controller,
                    presentation: .paged,
                    onTextChange: { statistics.update(chapter, plainText: $0) },
                    onPageCountChange: { laidOutPageCount = $0 }
                )
                .frame(minWidth: 360)

                if showNotes {
                    NotesPanel(data: notesBinding, documentID: chapter.objectID)
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 520)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom) {
            let words = statistics.wordCount(for: chapter)
            HStack {
                Spacer()
                Text("\(words) words · \(laidOutPageCount) \(laidOutPageCount == 1 ? "page" : "pages")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .help("Pages shown in the editor; every chapter begins on a new page.")
        }
        .onAppear { applyPendingJump() }
        .onChange(of: chapter) { applyPendingJump() }
        .onChange(of: navigator.target) { applyPendingJump() }
    }

    /// If the outline requested a jump into this chapter, scroll to it once the
    /// editor is showing this chapter. Deferred so the text view has loaded.
    private func applyPendingJump() {
        guard let target = navigator.target, target.chapterID == chapter.id else { return }
        DispatchQueue.main.async {
            controller.scroll(to: target.range)
            navigator.target = nil
        }
    }

    private var titleBinding: Binding<String> {
        Binding(get: { chapter.title ?? "" }, set: { chapter.title = $0 })
    }

    private var bodyBinding: Binding<Data?> {
        Binding(get: { chapter.bodyData }, set: { chapter.bodyData = $0 })
    }

    private var notesBinding: Binding<Data?> {
        Binding(get: { chapter.notesData }, set: { chapter.notesData = $0 })
    }
}
