//
//  ChapterDetailView.swift
//  Inkling
//
//  Detail pane for the selected chapter: an editable title, a formatting
//  toolbar, the rich-text body editor, and an optional side panel alongside
//  it (in a resizable split) that switches between per-chapter Notes and the
//  project-wide Shelf. Both the panel's visibility and which of the two it's
//  showing are shared across windows via @AppStorage.
//

import SwiftUI
import CoreData

/// Which content the resizable side panel shows. Persisted via @AppStorage,
/// so it needs a String raw value.
enum SidePanelMode: String {
    case notes, shelf
}

struct ChapterDetailView: View {
    @ObservedObject var chapter: Chapter
    @ObservedObject var project: Project
    @ObservedObject var statistics: StatisticsViewModel
    @ObservedObject var navigator: OutlineNavigator
    @StateObject private var controller = RichTextController()
    @State private var laidOutPageCount = 1
    @AppStorage("showSidePanel") private var showSidePanel = true
    @AppStorage("sidePanelMode") private var sidePanelMode = SidePanelMode.notes
    @AppStorage("typewriterScrolling") private var typewriterScrolling = true

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
                Button { typewriterScrolling.toggle() } label: {
                    Image(systemName: "align.vertical.center.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(typewriterScrolling ? Color.accentColor : Color.secondary)
                .tooltip(typewriterScrolling
                    ? "Turn Off Typewriter Scrolling"
                    : "Turn On Typewriter Scrolling — keeps the line you're writing fixed in place as the page scrolls beneath it")

                Button { showSidePanel.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showSidePanel ? Color.accentColor : Color.secondary)
                .tooltip(showSidePanel ? "Hide Panel" : "Show Panel")
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
                    onPageCountChange: { laidOutPageCount = $0 },
                    fontFamilyName: project.bodyFontFamily,
                    isTypewriterScrollingEnabled: typewriterScrolling
                )
                .frame(minWidth: 360)

                if showSidePanel {
                    VStack(spacing: 0) {
                        Picker("", selection: $sidePanelMode) {
                            Text("Notes").tag(SidePanelMode.notes)
                            Text("Shelf").tag(SidePanelMode.shelf)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(8)

                        Divider()

                        switch sidePanelMode {
                        case .notes:
                            NotesPanel(data: notesBinding, documentID: chapter.objectID, fontFamilyName: project.bodyFontFamily)
                        case .shelf:
                            ShelfView(project: project)
                        }
                    }
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
        .onChange(of: project.bodyFontFamily, initial: true) { _, newValue in
            controller.fontFamilyName = newValue
        }
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
