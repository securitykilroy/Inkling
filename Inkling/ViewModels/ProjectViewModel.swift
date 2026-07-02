//
//  ProjectViewModel.swift
//  Inkling
//
//  Owns the document-level state for a single project window: the root
//  Project object and the operations that mutate the chapter list. The
//  view layer talks to this; this talks to Core Data. Inserting/deleting
//  objects dirties the managed object context, which NSPersistentDocument
//  observes to drive autosave — so we never call context.save() directly.
//

import Combine
import CoreData
import SwiftUI

@MainActor
final class ProjectViewModel: ObservableObject {

    let context: NSManagedObjectContext
    @Published private(set) var project: Project

    init(context: NSManagedObjectContext) {
        self.context = context
        self.project = Self.fetchOrCreateProject(in: context)
    }

    /// There is exactly one Project per store. Fetch it, or create it on a
    /// brand-new document (which marks the document dirty so it autosaves).
    private static func fetchOrCreateProject(in context: NSManagedObjectContext) -> Project {
        let request = Project.fetchRequest()
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first {
            return existing
        }
        // Seed the root Project without registering undo, so a freshly created
        // (and otherwise untouched) document is not treated as having unsaved
        // changes. Document dirtiness is tracked via the undo manager, so an
        // unregistered insert won't nag the user to save on quit. The Project
        // is still persisted once the user makes a real, undoable edit.
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Untitled Project"
        project.createdAt = Date()
        context.processPendingChanges()
        undoManager?.enableUndoRegistration()
        return project
    }

    /// Appends a new chapter at the end of the list.
    @discardableResult
    func addChapter(title: String = "Untitled Chapter") -> Chapter {
        let chapter = Chapter(context: context)
        chapter.id = UUID()
        chapter.title = title
        chapter.createdAt = Date()
        chapter.sortIndex = (project.orderedChapters.last?.sortIndex ?? -1) + 1
        chapter.project = project
        objectWillChange.send()
        return chapter
    }

    /// Deletes a single chapter.
    func deleteChapter(_ chapter: Chapter) {
        context.delete(chapter)
        objectWillChange.send()
    }

    /// Deletes several chapters at once.
    func deleteChapters(_ chapters: [Chapter]) {
        chapters.forEach { context.delete($0) }
        objectWillChange.send()
    }

    /// Reorders chapters by reassigning `sortIndex` to match the new order.
    /// `ordered` is the chapter list as currently displayed (sorted by
    /// sortIndex); `source`/`destination` come from SwiftUI's `.onMove`.
    func moveChapters(_ ordered: [Chapter], from source: IndexSet, to destination: Int) {
        var reordered = ordered
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, chapter) in reordered.enumerated() {
            chapter.sortIndex = Int64(index)
        }
        objectWillChange.send()
    }
}
