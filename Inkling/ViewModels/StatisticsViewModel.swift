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
    private let pageCounter: @MainActor (Data?) -> Int
    @Published private(set) var wordCounts: [UUID: Int] = [:]
    /// Real laid-out page counts per chapter (keyed by UUID), so the sidebar
    /// total matches what the editor shows rather than a word-count estimate.
    /// Primed once on open by laying each chapter out off-screen, then kept
    /// live for the chapter being edited via `updatePageCount`.
    @Published private(set) var pageCounts: [UUID: Int] = [:]
    private struct BodySnapshot: Equatable {
        let data: Data?
    }
    /// The body each cached count was derived from. This lets an explicit
    /// refresh update existing chapters without re-laying unchanged ones out.
    private var bodySnapshots: [UUID: BodySnapshot] = [:]
    private var pendingPageSnapshots: [UUID: BodySnapshot] = [:]
    private var paginationTask: Task<Void, Never>?

    init(
        context: NSManagedObjectContext,
        pageCounter: @escaping @MainActor (Data?) -> Int = {
            PageStackView.pageCount(forRTF: $0)
        }
    ) {
        self.context = context
        self.pageCounter = pageCounter
    }

    /// Computes counts for all chapters in the store. Call when the view appears.
    func primeAll() {
        guard let chapters = try? context.fetch(Chapter.fetchRequest()) else { return }
        var words: [UUID: Int] = [:]
        var snapshots: [UUID: BodySnapshot] = [:]
        paginationTask?.cancel()
        pendingPageSnapshots.removeAll()
        for chapter in chapters {
            if let id = chapter.id {
                words[id] = TextStatistics.wordCount(inRTF: chapter.bodyData)
                let snapshot = BodySnapshot(data: chapter.bodyData)
                snapshots[id] = snapshot
                pendingPageSnapshots[id] = snapshot
            }
        }
        wordCounts = words
        pageCounts = [:]
        bodySnapshots = snapshots
        startPaginationIfNeeded()
    }

    /// Computes counts for chapters that don't have them yet, leaving existing
    /// entries alone. Call whenever the chapter set changes — importing a book
    /// adds chapters that `primeAll`'s one-time `onAppear` never sees.
    ///
    /// Must be called *outside* a view body. Word counts are refreshed here;
    /// the expensive page layouts are queued cooperatively on the main actor.
    func primeMissing(for chapters: [Chapter]) {
        var words = wordCounts
        var added = false
        for chapter in chapters {
            guard let id = chapter.id else { continue }
            let snapshot = BodySnapshot(data: chapter.bodyData)
            let bodyChanged = bodySnapshots[id] != snapshot
            if words[id] == nil || bodyChanged {
                words[id] = TextStatistics.wordCount(inRTF: chapter.bodyData)
                added = true
            }
            if pageCounts[id] == nil || bodyChanged {
                pendingPageSnapshots[id] = snapshot
                added = true
            }
            bodySnapshots[id] = snapshot
        }
        guard added else { return }
        wordCounts = words
        startPaginationIfNeeded()
    }

    /// Updates a single chapter's word count from the editor's live text (no RTF
    /// decode needed). Called from the body editor on every change.
    func update(_ chapter: Chapter, plainText: String) {
        guard let id = chapter.id else { return }
        wordCounts[id] = TextStatistics.wordCount(in: plainText)
        bodySnapshots[id] = BodySnapshot(data: chapter.bodyData)
    }

    /// Records the real page count the editor laid out for a chapter, so the
    /// sidebar total tracks the active chapter live without re-laying it out.
    func updatePageCount(_ chapter: Chapter, pages: Int) {
        guard let id = chapter.id else { return }
        pageCounts[id] = pages
        bodySnapshots[id] = BodySnapshot(data: chapter.bodyData)
        pendingPageSnapshots.removeValue(forKey: id)
    }

    /// TextKit pagination must run on the main actor, but doing every chapter
    /// in one synchronous loop blocks clicks and typing for the whole project.
    /// Process one snapshot per actor turn so AppKit can handle input between
    /// chapters, and discard a result if that chapter changed in the meantime.
    private func startPaginationIfNeeded() {
        guard paginationTask == nil, !pendingPageSnapshots.isEmpty else { return }
        paginationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }

            while !Task.isCancelled,
                  let (id, snapshot) = self.pendingPageSnapshots.first {
                self.pendingPageSnapshots.removeValue(forKey: id)
                let count = self.pageCounter(snapshot.data)
                if self.bodySnapshots[id] == snapshot {
                    self.pageCounts[id] = count
                }
                await Task.yield()
            }
            self.paginationTask = nil
            self.startPaginationIfNeeded()
        }
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
