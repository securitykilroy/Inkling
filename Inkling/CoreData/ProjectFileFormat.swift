//
//  ProjectFileFormat.swift
//  Inkling
//
//  Which Core Data store a `.inkling` file holds. Projects are saved as
//  SQLite; files written before that are XML stores and still open. They are
//  converted to SQLite the next time they are saved.
//
//  Why SQLite: an XML store is read into memory whole when it opens and
//  rewritten whole on every save, with every image base64-encoded (a third
//  larger) inside it. SQLite writes only the rows that changed, and the
//  project stays one file.
//

import CoreData

nonisolated enum ProjectFileFormat: Equatable {
    case sqlite
    case xml
    case unknown

    /// The store type new and re-saved projects are written in.
    static let storeType = NSSQLiteStoreType

    /// SQLite's default write-ahead log keeps `-wal` and `-shm` files beside
    /// the database for as long as it is open, which turns one project into
    /// three files next to the writer's own. A rollback journal exists only
    /// while a save is in progress and is gone when it commits.
    static let sqliteOptions: [String: Any] = [
        NSSQLitePragmasOption: ["journal_mode": "DELETE"],
    ]

    /// Reads the file's first bytes. Cheap, and doesn't need the model.
    static func detect(at url: URL) -> ProjectFileFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), !head.isEmpty else { return .unknown }
        if head.starts(with: Data("SQLite format 3\u{0}".utf8)) { return .sqlite }
        // An XML store begins with an XML declaration, possibly after a BOM
        // or whitespace.
        if let text = String(data: head, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{feff}"]))
               .hasPrefix("<?xml") {
            return .xml
        }
        return .unknown
    }

    /// The Core Data store type to open `url` with.
    static func storeType(forFileAt url: URL) -> String {
        detect(at: url) == .xml ? NSXMLStoreType : storeType
    }
}
