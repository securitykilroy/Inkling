//
//  ShelfEntry+CoreData.swift
//  Inkling
//
//  A single item parked on the project-wide Shelf: a scrap of prose dragged
//  out of a chapter, or a stray idea jotted down on its own. Rich text like
//  a chapter body, but project-scoped rather than tied to any one chapter.
//  `sortIndex` defines its position in the shelf list.
//

import Foundation
import CoreData

@objc(ShelfEntry)
public final class ShelfEntry: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ShelfEntry> {
        NSFetchRequest<ShelfEntry>(entityName: "ShelfEntry")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var sortIndex: Int64
    @NSManaged public var createdAt: Date?
    @NSManaged public var bodyData: Data?
    @NSManaged public var project: Project?
}
