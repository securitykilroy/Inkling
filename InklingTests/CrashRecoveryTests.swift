//
//  CrashRecoveryTests.swift
//  InklingTests
//
//  The safety copy of unsaved work (`CrashRecovery.swift`): it must capture
//  everything, live apart from the real file, and go away once the writer has
//  decided what to keep.
//

import AppKit
import CoreData
import Testing
@testable import Inkling

@Suite(.serialized)
@MainActor
struct CrashRecoveryTests {

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A project with two chapters and a shelf entry, none of it saved.
    @discardableResult
    private func populate(_ context: NSManagedObjectContext) -> Project {
        let project = Project(context: context)
        project.id = UUID()
        project.title = "The Lighthouse"
        project.author = "A. Writer"
        project.createdAt = Date()
        for (index, text) in ["Chapter one text.", "Chapter two text."].enumerated() {
            let chapter = Chapter(context: context)
            chapter.id = UUID()
            chapter.title = "Chapter \(index + 1)"
            chapter.sortIndex = Int64(index)
            chapter.createdAt = Date()
            chapter.bodyData = RichTextCodec.encode(NSAttributedString(string: text))
            chapter.project = project
        }
        let shelf = ShelfEntry(context: context)
        shelf.id = UUID()
        shelf.createdAt = Date()
        shelf.bodyData = RichTextCodec.encode(NSAttributedString(string: "A stray idea."))
        shelf.project = project
        return project
    }

    private func openStore(at url: URL) throws -> NSManagedObjectContext {
        let model = try #require(InklingDocument().managedObjectModel)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: CrashRecovery.storeType, configurationName: nil, at: url, options: nil
        )
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    @Test func snapshotCopiesEveryObjectAndRelationship() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let model = try #require(document.managedObjectModel)
        populate(context)
        // An unsaved deletion must not come back in the copy.
        let deleted = Chapter(context: context)
        deleted.id = UUID()
        deleted.title = "Cut"
        deleted.createdAt = Date()
        context.delete(deleted)

        let snapshot = try CrashRecovery.snapshot(of: context, displayName: "The Lighthouse", originalURL: nil)
        let url = directory.appendingPathComponent("copy.inkling")
        try CrashRecovery.write(snapshot, model: model, to: url)

        let restored = try openStore(at: url)
        let projects = try restored.fetch(Project.fetchRequest())
        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.title == "The Lighthouse")
        #expect(project.author == "A. Writer")
        let chapters = (project.chapters ?? []).sorted { $0.sortIndex < $1.sortIndex }
        #expect(chapters.map(\.title) == ["Chapter 1", "Chapter 2"])
        #expect(chapters.first?.bodyData.flatMap(RichTextCodec.decode)?.string == "Chapter one text.")
        #expect(project.shelfEntries?.count == 1)
        #expect(try restored.count(for: Chapter.fetchRequest()) == 2)
    }

    @Test func rewritingASnapshotReplacesTheOldCopy() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let model = try #require(document.managedObjectModel)
        let project = populate(context)
        let url = directory.appendingPathComponent("copy.inkling")

        try CrashRecovery.write(
            CrashRecovery.snapshot(of: context, displayName: "x", originalURL: nil), model: model, to: url
        )
        project.title = "Renamed"
        try CrashRecovery.write(
            CrashRecovery.snapshot(of: context, displayName: "x", originalURL: nil), model: model, to: url
        )

        let projects = try openStore(at: url).fetch(Project.fetchRequest())
        #expect(projects.map(\.title) == ["Renamed"])
        // No temporary files left behind beside the copy.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["copy.inkling"])
    }

    @Test func entriesDescribeCopiesNewestFirstAndSkipUnreadableFiles() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let model = try #require(document.managedObjectModel)
        populate(context)

        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let original = URL(fileURLWithPath: "/Users/someone/Documents/Book.inkling")
        try CrashRecovery.write(
            CrashRecovery.snapshot(of: context, displayName: "Untitled", originalURL: nil, date: older),
            model: model, to: directory.appendingPathComponent("a.inkling")
        )
        try CrashRecovery.write(
            CrashRecovery.snapshot(of: context, displayName: "Book", originalURL: original, date: newer),
            model: model, to: directory.appendingPathComponent("b.inkling")
        )
        try Data("not a store".utf8).write(to: directory.appendingPathComponent("junk.inkling"))

        let entries = CrashRecovery.entries(in: directory)

        #expect(entries.map(\.displayName) == ["Book", "Untitled"])
        #expect(entries.map(\.originalPath) == [original.path, nil])
        #expect(entries.map(\.snapshotDate) == [newer, older])
        // The unreadable file is skipped, not deleted.
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("junk.inkling").path))
    }

    @Test func recoveryOnlySnapshotsADocumentWithUnsavedChanges() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let recovery = DocumentRecovery(document: document, directory: directory)
        defer { recovery.stop() }

        populate(context)
        context.processPendingChanges()
        // Changes the document doesn't consider unsaved (like seeding a new,
        // untouched project) are not worth a copy.
        if document.isDocumentEdited { document.updateChangeCount(.changeCleared) }
        recovery.snapshotIfNeeded()
        recovery.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: recovery.url.path))

        document.updateChangeCount(.changeDone)
        recovery.snapshotIfNeeded()
        recovery.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: recovery.url.path))
    }

    @Test func recoverySkipsASnapshotWhenNothingChangedSinceTheLastOne() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let recovery = DocumentRecovery(document: document, directory: directory)
        defer { recovery.stop() }
        populate(context)
        context.processPendingChanges()
        document.updateChangeCount(.changeDone)

        recovery.snapshotIfNeeded()
        recovery.waitUntilIdle()
        try FileManager.default.removeItem(at: recovery.url)
        recovery.snapshotIfNeeded()
        recovery.waitUntilIdle()

        #expect(!FileManager.default.fileExists(atPath: recovery.url.path))
    }

    @Test func discardingDeletesTheCopy() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let recovery = DocumentRecovery(document: document, directory: directory)
        defer { recovery.stop() }
        populate(context)
        context.processPendingChanges()
        document.updateChangeCount(.changeDone)
        recovery.snapshotIfNeeded()

        recovery.discard()
        recovery.waitUntilIdle()

        #expect(!FileManager.default.fileExists(atPath: recovery.url.path))
    }

    /// A document reopened from a copy left by a crash must keep that copy
    /// (refreshing it) rather than starting a new one, and must count as
    /// unsaved so closing it asks to save.
    @Test func adoptingACopyKeepsItAndMarksTheDocumentUnsaved() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("left-by-crash.inkling")
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        populate(context)
        context.processPendingChanges()
        if document.isDocumentEdited { document.updateChangeCount(.changeCleared) }

        document.adoptRecoveredCopy(at: existing)
        let recovery = try #require(document.recovery)
        defer { recovery.stop() }

        #expect(document.isDocumentEdited)
        #expect(recovery.url == existing)
        recovery.snapshotIfNeeded()
        recovery.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: existing.path))
    }

    /// A SwiftUI text field writes its unchanged text back through its
    /// binding while the window lays out. That must not count as an edit, or
    /// merely opening a project makes closing it ask to save — and starts
    /// taking safety copies of nothing.
    @Test func assigningTheSameValueIsNotAnEdit() throws {
        let document = InklingDocument()
        let model = try #require(document.managedObjectModel)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let project = populate(context)
        try context.save()
        let chapter = try #require(project.chapters?.first)

        assignIfChanged(chapter, \.title, chapter.title)
        assignIfChanged(chapter, \.bodyData, chapter.bodyData.map { Data($0) })
        assignIfChanged(project, \.subtitle, nil)
        #expect(!context.hasChanges)

        assignIfChanged(chapter, \.title, "Renamed")
        #expect(context.hasChanges)
        #expect(chapter.title == "Renamed")
    }
}
