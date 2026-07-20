//
//  ProjectFindReplaceView.swift
//  Inkling
//
//  A sheet for finding and replacing text across every chapter in the
//  project, not just the one currently open in the editor. Search runs on
//  demand (Find button / Return), showing every match with surrounding
//  context before anything changes; clicking a match jumps to it in the
//  editor via the same OutlineNavigator jump-target mechanism the sidebar's
//  heading list already uses. Replace All rewrites every affected chapter's
//  bodyData directly — including chapters not currently open — and the
//  editor picks up the change automatically (see RichTextEditor.Coordinator's
//  loadedData tracking).
//

import SwiftUI
import CoreData

struct ProjectFindReplaceView: View {
    @ObservedObject var navigator: OutlineNavigator
    @Binding var selection: Chapter?

    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Chapter.sortIndex, ascending: true)])
    private var chapters: FetchedResults<Chapter>

    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = true
    @State private var matches: [SearchMatch] = []
    @State private var hasSearched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find & Replace in Project")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Find", text: $query, prompt: Text("Text to find in every chapter"))
                    .onSubmit(find)
                TextField("Replace", text: $replacement, prompt: Text("Leave blank to remove matches"))
                Toggle("Case-sensitive", isOn: $caseSensitive)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Find") { find() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.isEmpty)
                Spacer()
                if hasSearched {
                    Text(matches.isEmpty ? "No matches" : "\(matches.count) match\(matches.count == 1 ? "" : "es")")
                        .foregroundStyle(.secondary)
                }
            }

            List(matches) { match in
                Button {
                    jump(to: match)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.chapterTitle)
                            .font(.callout.weight(.semibold))
                        Text(snippet(for: match))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 160)
            .overlay {
                if hasSearched && matches.isEmpty {
                    ContentUnavailableView.search
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Replace All") { replaceAll() }
                    .disabled(matches.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private func find() {
        matches = ProjectSearch.findMatches(
            in: searchableChapters(), query: query, caseSensitive: caseSensitive
        )
        hasSearched = true
    }

    private func replaceAll() {
        let results = ProjectSearch.replaceAll(
            in: searchableChapters(), query: query, replacement: replacement, caseSensitive: caseSensitive
        )
        for chapter in chapters {
            guard let id = chapter.id, let newData = results[id] else { continue }
            chapter.bodyData = newData
        }
        // Re-run so the list reflects the change (matches should now be gone,
        // confirming the replacement worked, unless the replacement text
        // itself still contains the search text).
        find()
    }

    private func jump(to match: SearchMatch) {
        guard let chapter = chapters.first(where: { $0.id == match.chapterID }) else { return }
        selection = chapter
        navigator.target = OutlineJumpTarget(chapterID: match.chapterID, range: match.range)
    }

    private func searchableChapters() -> [SearchableChapter] {
        chapters.compactMap { chapter in
            guard let id = chapter.id else { return nil }
            return SearchableChapter(id: id, title: chapter.title ?? "Untitled Chapter", bodyData: chapter.bodyData)
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
