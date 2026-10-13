//
//  CrashRecovery.swift
//  Inkling
//
//  A safety copy of unsaved work, kept apart from the real document.
//
//  Inkling deliberately does not autosave in place (`autosavesInPlace` is
//  false): the file on disk only changes when the writer chooses Save, so a
//  version they want to get back to is never silently overwritten. The cost of
//  that choice is that a crash, force-quit, or power cut loses everything since
//  the last Save. This file closes that gap without giving up the guarantee.
//
//  While a document has unsaved changes, `DocumentRecovery` periodically writes
//  a complete copy of its in-memory state to a private Recovery folder in
//  Application Support — never to the document's own file. A normal Save,
//  Revert, or Close (including "Don't Save") deletes the copy, so one that
//  survives to the next launch means the app ended without the writer deciding
//  what to keep. The app delegate then offers to open each survivor as an
//  *untitled* document, so the writer chooses where (or whether) it is saved.
//

import AppKit
import CoreData

enum CrashRecovery {

    /// Seconds between safety copies while a document has unsaved changes.
    static let snapshotInterval: TimeInterval = 30

    /// Where safety copies live. Inside the sandbox container, so no
    /// file-access entitlement is needed and nothing appears beside the
    /// writer's own files.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Inkling/Recovery", isDirectory: true)
    }

    /// The store type every safety copy is written in — the same XML store a
    /// saved `.inkling` file uses, so a copy opens like any other project.
    static let storeType = NSXMLStoreType

    // Store-metadata keys describing what a safety copy is a copy of.
    static let displayNameKey = "InklingRecoveryDisplayName"
    static let originalPathKey = "InklingRecoveryOriginalPath"
    static let snapshotDateKey = "InklingRecoverySnapshotDate"

    /// A safety copy found on disk.
    struct Entry: Equatable {
        let url: URL
        /// The document's window title when the copy was taken.
        let displayName: String
        /// The saved file it came from; nil for a never-saved document.
        let originalPath: String?
        let snapshotDate: Date
    }

    /// The safety copies in `directory`, newest first. A file that isn't a
    /// readable store is skipped, never deleted — it may still be someone's
    /// only copy of their work.
    nonisolated static func entries(in directory: URL = CrashRecovery.directory) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "inkling" }
            .compactMap { url -> Entry? in
                guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: storeType, at: url, options: nil
                ) else { return nil }
                return Entry(
                    url: url,
                    displayName: metadata[displayNameKey] as? String ?? url.deletingPathExtension().lastPathComponent,
                    originalPath: metadata[originalPathKey] as? String,
                    snapshotDate: metadata[snapshotDateKey] as? Date ?? .distantPast
                )
            }
            .sorted { $0.snapshotDate > $1.snapshotDate }
    }

    // MARK: - Snapshots

    /// Everything in a context, copied out as plain values so it can be
    /// written off the main thread while the writer keeps typing.
    struct Snapshot: @unchecked Sendable {
        struct Object {
            let entityName: String
            let attributes: [String: Any]
            /// Relationship name → indices into `objects` of its destinations.
            let relationships: [String: [Int]]
            let isToMany: [String: Bool]
        }

        let objects: [Object]
        let metadata: [String: Any]
    }

    /// Copies every object in `context` — including unsaved inserts and edits,
    /// excluding unsaved deletions — along with the metadata describing it.
    /// Generic over the model, so a new entity or attribute is covered without
    /// touching this code.
    static func snapshot(
        of context: NSManagedObjectContext,
        displayName: String,
        originalURL: URL?,
        date: Date = Date()
    ) throws -> Snapshot {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else {
            return Snapshot(objects: [], metadata: [:])
        }

        var managedObjects: [NSManagedObject] = []
        for entity in model.entities where entity.superentity == nil {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.includesSubentities = true
            managedObjects += try context.fetch(request)
        }
        var index: [NSManagedObjectID: Int] = [:]
        for (offset, object) in managedObjects.enumerated() {
            index[object.objectID] = offset
        }

        let objects = managedObjects.map { object -> Snapshot.Object in
            var attributes: [String: Any] = [:]
            for name in object.entity.attributesByName.keys {
                if let value = object.value(forKey: name) {
                    attributes[name] = value
                }
            }
            var relationships: [String: [Int]] = [:]
            var isToMany: [String: Bool] = [:]
            for (name, relationship) in object.entity.relationshipsByName {
                isToMany[name] = relationship.isToMany
                if relationship.isToMany {
                    let set = object.value(forKey: name) as? NSSet ?? []
                    relationships[name] = set.compactMap { ($0 as? NSManagedObject).flatMap { index[$0.objectID] } }
                } else if let destination = object.value(forKey: name) as? NSManagedObject,
                          let destinationIndex = index[destination.objectID] {
                    relationships[name] = [destinationIndex]
                }
            }
            return Snapshot.Object(
                entityName: object.entity.name ?? "",
                attributes: attributes,
                relationships: relationships,
                isToMany: isToMany
            )
        }

        var metadata: [String: Any] = [
            displayNameKey: displayName,
            snapshotDateKey: date,
        ]
        if let originalURL {
            metadata[originalPathKey] = originalURL.path
        }
        return Snapshot(objects: objects, metadata: metadata)
    }

    /// Writes `snapshot` as a complete project store at `url`. The new copy is
    /// built beside the old one and swapped in only once it has saved, so a
    /// crash mid-write leaves the previous copy intact.
    nonisolated static func write(
        _ snapshot: Snapshot,
        model: NSManagedObjectModel,
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).inkling")
        defer { try? fileManager.removeItem(at: temporary) }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: storeType, configurationName: nil, at: temporary, options: nil
        )
        coordinator.setMetadata(
            store.metadata.merging(snapshot.metadata) { _, new in new },
            for: store
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        var saveError: Error?
        context.performAndWait {
            let copies = snapshot.objects.map { object in
                NSEntityDescription.insertNewObject(forEntityName: object.entityName, into: context)
            }
            for (copy, object) in zip(copies, snapshot.objects) {
                for (name, value) in object.attributes {
                    copy.setValue(value, forKey: name)
                }
                for (name, destinations) in object.relationships {
                    // Set each relationship from one side only; Core Data
                    // fills in the inverse.
                    if object.isToMany[name] == true {
                        copy.setValue(NSSet(array: destinations.map { copies[$0] }), forKey: name)
                    } else if let destination = destinations.first, copy.value(forKey: name) == nil {
                        copy.setValue(copies[destination], forKey: name)
                    }
                }
            }
            do { try context.save() } catch { saveError = error }
        }
        if let saveError { throw saveError }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}

/// Keeps one document's safety copy current while it has unsaved changes, and
/// removes it once the writer has decided what to keep.
final class DocumentRecovery {

    /// The safety copy for this document. Fresh per session, so a copy left by
    /// an earlier crash is never overwritten — unless this document *is* that
    /// copy reopened, in which case it adopts it (see `adopt(_:)`).
    private(set) var url: URL

    private weak var document: NSPersistentDocument?
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var hasChangesSinceSnapshot = false

    /// Serial, so a deletion queued after a write always runs after it.
    private let queue = DispatchQueue(label: "com.washere.Inkling.recovery")

    init(document: NSPersistentDocument, directory: URL = CrashRecovery.directory) {
        self.document = document
        self.url = directory.appendingPathComponent("\(UUID().uuidString).inkling")

        changeObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: document.managedObjectContext,
            // The document's context is a main-queue context, so this is
            // delivered synchronously on the main thread.
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasChangesSinceSnapshot = true }
        }
        let timer = Timer(timeInterval: CrashRecovery.snapshotInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshotIfNeeded() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    /// Takes over an existing safety copy: this document was opened from it,
    /// so later snapshots refresh it, and it goes away only when this document
    /// is saved or deliberately closed.
    func adopt(_ existing: URL) {
        url = existing
        hasChangesSinceSnapshot = true
    }

    /// Writes a fresh copy if the document has unsaved changes it hasn't
    /// captured yet. Called by the timer; callable directly from tests.
    func snapshotIfNeeded() {
        guard hasChangesSinceSnapshot,
              let document,
              document.isDocumentEdited,
              let context = document.managedObjectContext,
              let model = context.persistentStoreCoordinator?.managedObjectModel
        else { return }

        let snapshot: CrashRecovery.Snapshot
        do {
            snapshot = try CrashRecovery.snapshot(
                of: context,
                displayName: document.displayName,
                originalURL: document.fileURL
            )
        } catch {
            NSLog("Inkling: could not capture a recovery snapshot: \(error)")
            return
        }
        hasChangesSinceSnapshot = false

        let url = self.url
        queue.async {
            do {
                try CrashRecovery.write(snapshot, model: model, to: url)
            } catch {
                NSLog("Inkling: could not write a recovery snapshot: \(error)")
            }
        }
    }

    /// Deletes the safety copy — the writer saved, reverted, or chose not to
    /// keep their changes. Any write already queued finishes first.
    func discard() {
        hasChangesSinceSnapshot = false
        let url = self.url
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stops taking snapshots. The document is going away.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Blocks until queued writes and deletions have finished. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }
}
