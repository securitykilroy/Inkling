//
//  StatisticsViewModel.swift
//  Inkling
//
//  Tracks word counts for the project. Counts are cached per chapter (keyed by
//  the chapter's stable UUID, which survives Core Data save/objectID changes)
//  so the project total updates live without re-decoding every chapter's RTF on
//  each keystroke. The editor reports the current chapter's plain text on every
//  edit; everything else is primed once when the document opens.
//

import Combine
import CoreData

@MainActor
final class StatisticsViewModel: ObservableObject {

    private let context: NSManagedObjectContext
    @Published private(set) var wordCounts: [UUID: Int] = [:]
    /// Real laid-out page counts per chapter (keyed by UUID), so the sidebar
    /// total matches what the editor shows rather than a word-count estimate.
    /// Primed once on open by laying each chapter out off-screen, then kept
    /// live for the chapter being edited via `updatePageCount`.
    @Published private(set) var pageCounts: [UUID: Int] = [:]

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Computes counts for all chapters in the store. Call when the view appears.
    func primeAll() {
        guard let chapters = try? context.fetch(Chapter.fetchRequest()) else { return }
        var words: [UUID: Int] = [:]
        var pages: [UUID: Int] = [:]
        for chapter in chapters {
            if let id = chapter.id {
                words[id] = TextStatistics.wordCount(inRTF: chapter.bodyData)
                pages[id] = PagedTextView.pageCount(forRTF: chapter.bodyData)
            }
        }
        wordCounts = words
        pageCounts = pages
    }

    /// Updates a single chapter's word count from the editor's live text (no RTF
    /// decode needed). Called from the body editor on every change.
    func update(_ chapter: Chapter, plainText: String) {
        guard let id = chapter.id else { return }
        wordCounts[id] = TextStatistics.wordCount(in: plainText)
    }

    /// Records the real page count the editor laid out for a chapter, so the
    /// sidebar total tracks the active chapter live without re-laying it out.
    func updatePageCount(_ chapter: Chapter, pages: Int) {
        guard let id = chapter.id else { return }
        pageCounts[id] = pages
    }

    func wordCount(for chapter: Chapter) -> Int {
        if let id = chapter.id, let cached = wordCounts[id] { return cached }
        return TextStatistics.wordCount(inRTF: chapter.bodyData)
    }

    func pageCount(for chapter: Chapter) -> Int {
        if let id = chapter.id, let cached = pageCounts[id] { return cached }
        return PagedTextView.pageCount(forRTF: chapter.bodyData)
    }

    func totalWords(for chapters: [Chapter]) -> Int {
        chapters.reduce(0) { $0 + wordCount(for: $1) }
    }

    /// Sum of each chapter's real page count. Summed per chapter — not counted
    /// from the combined text — because every chapter starts on a new page.
    func totalPages(for chapters: [Chapter]) -> Int {
        chapters.reduce(0) { $0 + pageCount(for: $1) }
    }
}
