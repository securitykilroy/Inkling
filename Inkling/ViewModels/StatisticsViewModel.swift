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

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Computes counts for all chapters in the store. Call when the view appears.
    func primeAll() {
        guard let chapters = try? context.fetch(Chapter.fetchRequest()) else { return }
        var counts: [UUID: Int] = [:]
        for chapter in chapters {
            if let id = chapter.id {
                counts[id] = TextStatistics.wordCount(inRTF: chapter.bodyData)
            }
        }
        wordCounts = counts
    }

    /// Updates a single chapter's count from the editor's live text (no RTF
    /// decode needed). Called from the body editor on every change.
    func update(_ chapter: Chapter, plainText: String) {
        guard let id = chapter.id else { return }
        wordCounts[id] = TextStatistics.wordCount(in: plainText)
    }

    func wordCount(for chapter: Chapter) -> Int {
        if let id = chapter.id, let cached = wordCounts[id] { return cached }
        return TextStatistics.wordCount(inRTF: chapter.bodyData)
    }

    func pageEstimate(for chapter: Chapter) -> Int {
        TextStatistics.pageEstimate(forWords: wordCount(for: chapter))
    }

    func totalWords(for chapters: [Chapter]) -> Int {
        chapters.reduce(0) { $0 + wordCount(for: $1) }
    }

    /// Sum of each chapter's page estimate — not the page estimate of the
    /// combined word count — because every chapter starts on a new page.
    func totalPages(for chapters: [Chapter]) -> Int {
        chapters.reduce(0) { $0 + pageEstimate(for: $1) }
    }
}
