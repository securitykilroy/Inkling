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

    /// The saved position for the document at `url`, or nil if none was stored
    /// (a never-opened file) or the stored data can't be decoded.
    static func position(for url: URL) -> LastEditPosition? {
        loadAll()[url.path]
    }

    /// Records `position` as the place to return to for the document at `url`.
    static func save(_ position: LastEditPosition, for url: URL) {
        var all = loadAll()
        all[url.path] = position
        persist(all)
    }

    /// Forgets any stored position for the document at `url`.
    static func clear(for url: URL) {
        var all = loadAll()
        guard all.removeValue(forKey: url.path) != nil else { return }
        persist(all)
    }

    private static func loadAll() -> [String: LastEditPosition] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: LastEditPosition].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persist(_ all: [String: LastEditPosition]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}
