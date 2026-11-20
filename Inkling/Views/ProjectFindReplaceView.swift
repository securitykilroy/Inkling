//
//  ProjectFindReplaceView.swift
//  Inkling
//
//  An inspector panel for finding and replacing text across every chapter in the
//  project, not just the one currently open in the editor. Search runs on
//  demand (Find button / Return), showing every match with surrounding
//  context before anything changes; clicking a match jumps to it in the
//  editor via the same OutlineNavigator jump-target mechanism the sidebar's
//  heading list already uses. It searches each chapter's body, notes, sidebar
//  boxes and captions (see `ProjectSearch`). Replace All rewrites every affected chapter's
//  bodyData/notesData directly — including chapters not currently open — and the
//  editor picks up the change automatically (see RichTextEditor.Coordinator's
//  loadedData tracking).
//
//  It sits beside the editor rather than over it, so the editor stays usable:
//  click a match, fix it in place, click the next.
//

import SwiftUI
import CoreData

struct ProjectFindReplaceView: View {
    @ObservedObject var navigator: OutlineNavigator
    @ObservedObject var statistics: StatisticsViewModel
    @Binding var selection: Chapter?
    @Binding var isPresented: Bool

    @FocusState private var findFieldFocused: Bool
    @EnvironmentObject private var commands: ProjectCommands
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Chapter.sortIndex, ascending: true)])
    private var chapters: FetchedResults<Chapter>

    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = true
    @State private var searchResult: ProjectSearchResult?

    var body: some View {
        let currentResult = searchResult.flatMap {
            $0.isCurrent(query: query, caseSensitive: caseSensitive) ? $0 : nil
        }
        let matches = currentResult?.matches ?? []
        let hasSearched = currentResult != nil

        VStack(alignment: .leading, spacing: 12) {
            Text("Find & Replace in Project")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Find", text: $query, prompt: Text("Text to find in every chapter"))
                    .focused($findFieldFocused)
                    .onSubmit(find)
                TextField("Replace", text: $replacement, prompt: Text("Leave blank to remove matches"))
                Toggle("Case-sensitive", isOn: $caseSensitive)
            }
            .textFieldStyle(.roundedBorder)
            // In an inspector a Form otherwise takes all the height it can,
            // pushing the Find button halfway down the panel.
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                // No `.keyboardShortcut(.defaultAction)`: in a panel that
                // isn't modal it would take Return from the whole window, so
                // pressing Return in the chapter would run Find. Return in the
                // Find field searches (`onSubmit`).
                Button("Find") { find() }
                    .disabled(query.isEmpty)
                Spacer()
                if hasSearched {
                    Text(matches.isEmpty ? "No matches" : "\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .foregroundStyle(.secondary)
                }
            }

            // A plain scrolling stack, not a List: a List takes the first
            // click while the Find field has focus to focus itself, so the
            // first match clicked after a search silently did nothing.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { match in
                        Button {
                            jump(to: match)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(match.chapterTitle)
                                        .font(.callout.weight(.semibold))
                                    if let label = match.place.label {
                                        Text("· \(label)")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                                Text(snippet(for: match))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 160, maxHeight: .infinity)
            .overlay {
                if hasSearched && matches.isEmpty {
                    ContentUnavailableView.search
                }
            }

            HStack {
                Spacer()
                Button("Close") { isPresented = false }
                Button("Replace All") { replaceAll() }
                    .disabled(matches.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The editor keeps the keyboard while the inspector animates in, so
        // focusing in `onAppear` alone was lost and typing went into the
        // chapter. Ask again once the panel is up, and on every request.
        .task(id: commands.findFocusRequests) {
            try? await Task.sleep(for: .milliseconds(150))
            findFieldFocused = true
        }
    }

    private func find() {
        searchResult = ProjectSearchResult(
            query: query,
            caseSensitive: caseSensitive,
            matches: ProjectSearch.findMatches(
                in: searchableChapters(), query: query, caseSensitive: caseSensitive
            )
        )
    }

    private func replaceAll() {
        guard searchResult?.isCurrent(query: query, caseSensitive: caseSensitive) == true else {
            return
        }
        let results = ProjectSearch.replaceAll(
            in: searchableChapters(), query: query, replacement: replacement, caseSensitive: caseSensitive
        )
        var affected: [Chapter] = []
        var changes: [RichTextChange] = []
        for chapter in chapters {
            guard let id = chapter.id, let result = results[id] else { continue }
            if let body = result.bodyData {
                changes.append(RichTextChange(
                    object: chapter, key: #keyPath(Chapter.bodyData), from: chapter.bodyData, to: body
                ))
            }
            if let notes = result.notesData {
                changes.append(RichTextChange(
                    object: chapter, key: #keyPath(Chapter.notesData), from: chapter.notesData, to: notes
                ))
            }
            affected.append(chapter)
        }
        // One undoable step of its own, outside Core Data's undo like every
        // write to a chapter's text: see `applyRichTextChanges`.
        if let context = affected.first?.managedObjectContext {
            applyRichTextChanges(changes, actionName: "Replace All", in: context)
        }
        statistics.primeMissing(for: affected)
        // Re-run so the list reflects the change (matches should now be gone,
        // confirming the replacement worked, unless the replacement text
        // itself still contains the search text).
        find()
    }

    private func jump(to match: SearchMatch) {
        guard let chapter = chapters.first(where: { $0.id == match.chapterID }) else { return }
        selection = chapter
        navigator.target = OutlineJumpTarget(chapterID: match.chapterID, range: match.range, place: match.place)
    }

    private func searchableChapters() -> [SearchableChapter] {
        chapters.compactMap { chapter in
            guard let id = chapter.id else { return nil }
            return SearchableChapter(
                id: id, title: chapter.title ?? "Untitled Chapter",
                bodyData: chapter.bodyData, notesData: chapter.notesData
            )
        }
    }

    private func snippet(for match: SearchMatch) -> AttributedString {
        var result = AttributedString(match.snippetBefore)
        var highlighted = AttributedString(match.snippetMatch)
        highlighted.font = .callout.bold()
        highlighted.foregroundColor = .accentColor
        result += highlighted
        result += AttributedString(match.snippetAfter)
        return result
    }
}
