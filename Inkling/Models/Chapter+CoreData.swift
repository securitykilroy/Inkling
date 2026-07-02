//
//  Chapter+CoreData.swift
//  Inkling
//
//  A single chapter/section within a Project. Holds the rich-text body and
//  a separate rich-text notes field, both archived as Data. `sortIndex`
//  defines the chapter's position in the sidebar.
//

import Foundation
import CoreData

@objc(Chapter)
public final class Chapter: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Chapter> {
        NSFetchRequest<Chapter>(entityName: "Chapter")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var title: String?
    @NSManaged public var sortIndex: Int64
    @NSManaged public var createdAt: Date?
    @NSManaged public var bodyData: Data?
    @NSManaged public var notesData: Data?
    @NSManaged public var project: Project?
}
