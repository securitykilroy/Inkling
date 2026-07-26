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
                pages[id] = PageStackView.pageCount(forRTF: chapter.bodyData)
            }
        }
        wordCounts = words
        pageCounts = pages
    }

    /// Computes counts for chapters that don't have them yet, leaving existing
    /// entries alone. Call whenever the chapter set changes — importing a book
    /// adds chapters that `primeAll`'s one-time `onAppear` never sees.
    ///
    /// Must be called *outside* a view body. Both counts decode the chapter's
    /// RTF and one of them lays the whole chapter out; doing that during a
    /// render is what made a single keystroke re-paginate the entire book.
    func primeMissing(for chapters: [Chapter]) {
        var words = wordCounts
        var pages = pageCounts
        var added = false
        for chapter in chapters {
            guard let id = chapter.id else { continue }
            if words[id] == nil {
                words[id] = TextStatistics.wordCount(inRTF: chapter.bodyData)
                added = true
            }
            if pages[id] == nil {
                pages[id] = PageStackView.pageCount(forRTF: chapter.bodyData)
                added = true
            }
        }
        guard added else { return }
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

    // These are read from view bodies, so they must stay cheap: cache hit or a
    // trivial fallback, never a decode or a layout. They previously fell back to
    // computing the real value, and because the result was never stored, an
    // un-primed chapter recomputed on *every* SwiftUI render. After importing a
    // book none of the new chapters were primed, so each keystroke in the
    // sidebar re-decoded and re-paginated all of them — measured at ~0.4-0.8s
    // per chapter, several seconds per keystroke. `primeMissing(for:)` fills
    // these in from outside the render pass.

    func wordCount(for chapter: Chapter) -> Int {
        guard let id = chapter.id else { return 0 }
        return wordCounts[id] ?? 0
    }

    /// Every chapter occupies at least one page, so an un-primed chapter reads
    /// as 1 rather than 0 — the total is briefly low instead of briefly absurd.
    func pageCount(for chapter: Chapter) -> Int {
        guard let id = chapter.id else { return 1 }
        return pageCounts[id] ?? 1
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
