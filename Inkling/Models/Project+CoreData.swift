//
//  Project+CoreData.swift
//  Inkling
//
//  The root entity of an Inkling document. Exactly one Project lives in
//  each document's Core Data store; it owns an ordered set of Chapters.
//

import Foundation
import CoreData

@objc(Project)
public final class Project: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Project> {
        NSFetchRequest<Project>(entityName: "Project")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var title: String?
    @NSManaged public var subtitle: String?
    @NSManaged public var author: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var bodyFontFamily: String?
    @NSManaged public var projectNotesData: Data?
    @NSManaged public var chapters: Set<Chapter>?
    @NSManaged public var shelfEntries: Set<ShelfEntry>?
}

extension Project {
    /// Chapters in display order (by `sortIndex`).
    var orderedChapters: [Chapter] {
        (chapters ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Shelf entries in display order (by `sortIndex`).
    var orderedShelfEntries: [ShelfEntry] {
        (shelfEntries ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }
}
