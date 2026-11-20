//
//  LastEditPositionStore.swift
//  Inkling
//
//  Remembers where the user last was in each document — which chapter and the
//  caret offset within it — so reopening a file jumps back there. Kept in
//  UserDefaults keyed by the document's file path, deliberately *outside* the
//  .inkling file: navigating shouldn't dirty the document (autosavesInPlace is
//  false, so that would nag the user to save), and this is per-Mac state that
//  needn't travel with the file.
//

import Foundation

/// A restorable cursor location within a document: a chapter plus the caret's
/// character offset in that chapter's body.
nonisolated struct LastEditPosition: Codable, Equatable {
    let chapterID: UUID
    let caret: Int
}

/// Reads and writes `LastEditPosition` values, one per document, keyed by the
/// document's file path. Backed by `UserDefaults`.
nonisolated enum LastEditPositionStore {
    /// Overridable so tests can use an isolated defaults suite.
    static var defaults: UserDefaults = .standard

    private static let key = "lastEditPositions"

    /// Most documents to remember. Keying by file path means a renamed or moved
    /// document leaves its old entry behind with nothing left to match it, so
    /// without a bound this grew for the life of the install. The bound is the
    /// only pruning: entries are never dropped for a file that seems missing
    /// (see `pruned`).
    static let maximumEntries = 200

    /// One document's stored entry. Deliberately flat — the same keys the
    /// position itself has, plus an optional timestamp — so entries written
    /// before eviction existed still decode, and the timestamp stays out of
    /// `LastEditPosition`, where it would leak into equality.
    struct Entry: Codable, Equatable {
        let chapterID: UUID
        let caret: Int
        /// When this was recorded, used to evict the oldest entries once the
        /// store is full. Entries written before this existed sort as oldest
        /// and are therefore evicted first.
        var savedAt: Date?

        var position: LastEditPosition {
            LastEditPosition(chapterID: chapterID, caret: caret)
        }

        init(_ position: LastEditPosition, savedAt: Date?) {
            self.chapterID = position.chapterID
            self.caret = position.caret
            self.savedAt = savedAt
        }
    }

    /// The saved position for the document at `url`, or nil if none was stored
    /// (a never-opened file) or the stored data can't be decoded.
    static func position(for url: URL) -> LastEditPosition? {
        loadAll()[url.path]?.position
    }

    /// Records `position` as the place to return to for the document at `url`,
    /// then, if the store is over its limit, drops the least recently saved
    /// entries.
    static func save(_ position: LastEditPosition, for url: URL) {
        var all = loadAll()
        all[url.path] = Entry(position, savedAt: Date())
        persist(pruned(all, keeping: url.path))
    }

    /// Forgets any stored position for the document at `url`.
    static func clear(for url: URL) {
        var all = loadAll()
        guard all.removeValue(forKey: url.path) != nil else { return }
        persist(all)
    }

    /// Caps the store at `maximumEntries`, oldest first. `keeping` is the entry
    /// just written, which is never the one evicted.
    ///
    /// This used to drop every entry whose file `fileExists` couldn't see.
    /// That's also true of a document on an unplugged drive or an unmounted
    /// network volume — and, in the App Sandbox, of any closed document outside
    /// the container — so saving one document's position could wipe the
    /// others'. The cap alone bounds the store.
    static func pruned(
        _ all: [String: Entry],
        keeping keptPath: String? = nil
    ) -> [String: Entry] {
        var remaining = all
        guard remaining.count > maximumEntries else { return remaining }

        let evictable = remaining
            .filter { $0.key != keptPath }
            .sorted { ($0.value.savedAt ?? .distantPast) < ($1.value.savedAt ?? .distantPast) }
        for entry in evictable.prefix(remaining.count - maximumEntries) {
            remaining.removeValue(forKey: entry.key)
        }
        return remaining
    }

    private static func loadAll() -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persist(_ all: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}
