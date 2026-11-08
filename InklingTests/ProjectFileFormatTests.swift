//
//  ProjectFileFormatTests.swift
//  InklingTests
//
//  Projects are saved as single-file SQLite stores. Legacy XML projects must
//  still open, and convert to SQLite on their next save without losing
//  anything or leaving extra files beside the project.
//

import AppKit
import CoreData
import Testing
@testable import Inkling

@Suite(.serialized)
@MainActor
struct ProjectFileFormatTests {

    private static let typeName = "com.washere.inkling-project"

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectFileFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a legacy XML project with one chapter, the way every project was
    /// saved before the switch to SQLite.
    private func writeLegacyXMLProject(at url: URL, body: Data?) throws {
        let model = try #require(InklingDocument().managedObjectModel)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSXMLStoreType, configurationName: nil, at: url, options: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Legacy"
        project.createdAt = Date()
        let chapter = Chapter(context: context)
        chapter.id = UUID()
        chapter.title = "One"
        chapter.sortIndex = 0
        chapter.createdAt = Date()
        chapter.bodyData = body
        chapter.project = project
        try context.save()
    }

    private func save(
        _ document: NSDocument,
        to url: URL,
        _ operation: NSDocument.SaveOperationType
    ) async throws {
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: Self.typeName, for: operation) { error in
                continuation.resume(returning: error)
            }
        }
        if let error { throw error }
    }

    private func chapters(in document: InklingDocument) throws -> [Chapter] {
        let context = try #require(document.managedObjectContext)
        let request = Chapter.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        return try context.fetch(request)
    }

    /// Everything in the directory except the project itself.
    private func strayFiles(in directory: URL, besides project: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != project.lastPathComponent }
    }

    private func body(_ text: String) -> Data? {
        RichTextCodec.encode(NSAttributedString(string: text))
    }

    @Test func formatDetectionRecognizesBothStores() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = directory.appendingPathComponent("a.inkling")
        try writeLegacyXMLProject(at: xml, body: body("x"))
        #expect(ProjectFileFormat.detect(at: xml) == .xml)

        let sqlite = directory.appendingPathComponent("b.inkling")
        let model = try #require(InklingDocument().managedObjectModel)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: sqlite,
            options: ProjectFileFormat.sqliteOptions
        )
        #expect(ProjectFileFormat.detect(at: sqlite) == .sqlite)
        #expect(ProjectFileFormat.detect(at: directory.appendingPathComponent("missing")) == .unknown)
    }

    /// The upgrade path: an XML project opens, saves as SQLite in place, and
    /// keeps every change made before and after the conversion.
    @Test func aLegacyXMLProjectConvertsToSQLiteWhenSaved() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Legacy.inkling")
        let original = body("The original text.")
        try writeLegacyXMLProject(at: url, body: original)

        let document = try InklingDocument(contentsOf: url, ofType: Self.typeName)
        #expect(try chapters(in: document).first?.bodyData == original)
        try chapters(in: document).first?.title = "Edited before conversion"
        try await save(document, to: url, .saveOperation)

        #expect(ProjectFileFormat.detect(at: url) == .sqlite)
        #expect(try strayFiles(in: directory, besides: url).isEmpty)

        // A second save after conversion writes in place, still one file.
        let revised = body("Revised after conversion.")
        try chapters(in: document).first?.bodyData = revised
        try await save(document, to: url, .saveOperation)
        #expect(try strayFiles(in: directory, besides: url).isEmpty)
        document.close()

        let reopened = try InklingDocument(contentsOf: url, ofType: Self.typeName)
        defer { reopened.close() }
        let chapter = try #require(try chapters(in: reopened).first)
        #expect(chapter.title == "Edited before conversion")
        #expect(chapter.bodyData == revised)
        #expect(chapter.project?.title == "Legacy")
    }

    /// A brand-new project's first save creates a single SQLite file.
    @Test func aNewProjectSavesAsSingleFileSQLite() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("New.inkling")

        let document = try InklingDocument(type: Self.typeName)
        let context = try #require(document.managedObjectContext)
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Fresh"
        project.createdAt = Date()
        try await save(document, to: url, .saveAsOperation)

        #expect(ProjectFileFormat.detect(at: url) == .sqlite)
        #expect(try strayFiles(in: directory, besides: url).isEmpty)

        project.title = "Fresh, edited"
        try await save(document, to: url, .saveOperation)
        document.close()

        let reopened = try InklingDocument(contentsOf: url, ofType: Self.typeName)
        defer { reopened.close() }
        let projects = try #require(reopened.managedObjectContext).fetch(Project.fetchRequest())
        #expect(projects.map(\.title) == ["Fresh, edited"])
    }

    /// Save As from a legacy project writes SQLite to the new place and leaves
    /// the original XML file untouched.
    @Test func saveAsFromALegacyProjectLeavesTheOriginalAlone() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Legacy.inkling")
        try writeLegacyXMLProject(at: url, body: body("Text"))
        let before = try Data(contentsOf: url)

        let document = try InklingDocument(contentsOf: url, ofType: Self.typeName)
        try chapters(in: document).first?.title = "Changed"
        let copy = directory.appendingPathComponent("Copy.inkling")
        try await save(document, to: copy, .saveAsOperation)
        document.close()

        #expect(try Data(contentsOf: url) == before)
        #expect(ProjectFileFormat.detect(at: copy) == .sqlite)
        let reopened = try InklingDocument(contentsOf: copy, ofType: Self.typeName)
        defer { reopened.close() }
        #expect(try chapters(in: reopened).first?.title == "Changed")
    }

    /// The sandbox lets SQLite create its journal beside a project only while
    /// a file presenter names that journal as a related item of the project.
    /// Without it every in-place save failed (SQLite error 21). The sandbox
    /// itself can't be exercised here, so check the presenter's wiring.
    @Test func anOpenProjectPresentsItsJournalAsARelatedItem() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Journal.inkling")
        try writeLegacyXMLProject(at: url, body: body("Text"))

        func journalPresenters() -> [NSFilePresenter] {
            NSFileCoordinator.filePresenters.filter { presenter in
                let primary: URL? = presenter.primaryPresentedItemURL ?? nil
                return primary?.standardizedFileURL.path == url.standardizedFileURL.path
            }
        }

        let document = try InklingDocument(contentsOf: url, ofType: Self.typeName)
        let presenter = try #require(journalPresenters().first)
        #expect(presenter.presentedItemURL?.path == url.path + "-journal")
        #expect(journalPresenters().count == 1)

        document.close()
        #expect(journalPresenters().isEmpty)
    }
}
