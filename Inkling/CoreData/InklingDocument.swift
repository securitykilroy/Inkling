//
//  InklingDocument.swift
//  Inkling
//
//  The document. Each open Inkling project is one NSPersistentDocument
//  backed by its own Core Data store (a single .inkling file). The document
//  creates its window in makeWindowControllers(), hosting the SwiftUI UI via
//  NSHostingController and injecting the document's managed object context.
//

import Cocoa
import CoreData
import SwiftUI
import UniformTypeIdentifiers

@objc(InklingDocument)
final class InklingDocument: NSPersistentDocument {

    /// A single, shared managed object model for every open document.
    ///
    /// By default each NSPersistentDocument builds its own NSManagedObjectModel.
    /// With more than one document open, multiple model instances each contain
    /// the `Project`/`Chapter` entities, and both models claim the same
    /// `@objc` subclass — so `+[Project entity]` can no longer disambiguate and
    /// creating/fetching objects traps. Sharing one model instance fixes it.
    private static let sharedModel: NSManagedObjectModel = {
        if let url = Bundle.main.url(forResource: "Inkling", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: url) {
            return model
        }
        if let url = Bundle.main.url(forResource: "Inkling", withExtension: "mom"),
           let model = NSManagedObjectModel(contentsOf: url) {
            return model
        }
        return NSManagedObjectModel.mergedModel(from: [Bundle.main]) ?? NSManagedObjectModel()
    }()

    override var managedObjectModel: NSManagedObjectModel? {
        Self.sharedModel
    }

    /// Enable automatic lightweight migration so documents written by an older
    /// model (e.g. before `Project.author` existed) still open. The change is
    /// additive and optional, so Core Data can infer the mapping.
    override func configurePersistentStoreCoordinator(
        for url: URL,
        ofType fileType: String,
        modelConfiguration configuration: String?,
        storeOptions: [String: Any]? = nil
    ) throws {
        var options = storeOptions ?? [:]
        options[NSMigratePersistentStoresAutomaticallyOption] = true
        options[NSInferMappingModelAutomaticallyOption] = true
        try super.configurePersistentStoreCoordinator(
            for: url,
            ofType: fileType,
            modelConfiguration: configuration,
            storeOptions: options
        )
    }

    /// Keep explicit save semantics: an edited existing project must ask the
    /// user to save when its window closes or the application quits.
    override nonisolated class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        guard let context = managedObjectContext else {
            assertionFailure("Document has no managed object context")
            return
        }

        let rootView = ProjectRootView(
            context: context,
            documentName: displayName,
            onSelectionChange: { [weak self] id in self?.currentChapterID = id }
        )
        .environment(\.managedObjectContext, context)

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        // Matches the comfortable working size chosen while testing. The
        // title bar brings the complete window to roughly 984 x 967 points.
        window.setContentSize(NSSize(width: 984, height: 915))
        window.minSize = NSSize(width: 760, height: 480)
        window.title = displayName

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = true
        addWindowController(controller)
    }

    // MARK: - Project Notes

    /// The project-wide scratchpad window (see `ProjectNotesView`). Created
    /// lazily the first time the user shows it, then kept alive across hide/show
    /// so its editor state and scroll position persist — `isReleasedWhenClosed`
    /// is left off so closing/toggling only orders it out rather than freeing it.
    private var projectNotesWindow: NSWindow?

    /// The single root `Project` in this document's store, or nil before it
    /// exists. `fetch` returns `[Project]`, so `.first` is `Project?`.
    private func rootProject() -> Project? {
        try? managedObjectContext?.fetch(Project.fetchRequest()).first
    }

    /// Show the notes window (creating it on first use) or hide it if it's
    /// already the front-facing window. Wired to the Window menu through the
    /// responder chain, like the print/export actions below.
    @objc func toggleProjectNotes(_ sender: Any?) {
        if let window = projectNotesWindow, window.isVisible {
            window.orderOut(nil)
            return
        }
        showProjectNotesWindow()
    }

    private func showProjectNotesWindow() {
        if projectNotesWindow == nil {
            guard let context = managedObjectContext, let project = rootProject() else {
                NSSound.beep()
                return
            }

            let rootView = ProjectNotesView(project: project)
                .environment(\.managedObjectContext, context)
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 600))
            window.minSize = NSSize(width: 320, height: 240)
            window.title = "Project Notes — \(bookTitle())"
            projectNotesWindow = window
        }
        projectNotesWindow?.makeKeyAndOrderFront(nil)
    }

    /// Keep the menu item's title in sync with the window's state. NSDocument
    /// routes menu validation for its own actions through here (it implements
    /// `NSUserInterfaceValidations`); we override to relabel our item and defer
    /// to `super` for every other document action (Save, Print, etc.).
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleProjectNotes(_:)) {
            if let menuItem = item as? NSMenuItem {
                let showing = projectNotesWindow?.isVisible ?? false
                menuItem.title = showing ? "Hide Project Notes" : "Show Project Notes"
            }
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// The notes window is a satellite of the project window, so it must never
    /// outlive the document. `close()` fires when the document closes for any
    /// reason (window close, quit), so tear the notes window down here.
    override func close() {
        projectNotesWindow?.close()
        projectNotesWindow = nil
        super.close()
    }

    // MARK: - Printing

    /// The chapter currently shown in the editor, reported by the SwiftUI view.
    /// Used by "Print Chapter…".
    private var currentChapterID: NSManagedObjectID?

    private func orderedChapters() -> [Chapter] {
        guard let context = managedObjectContext else { return [] }
        let request = Chapter.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Chapter.sortIndex, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// The book title for running heads and the title page: the project's title
    /// if the user set one, otherwise the document's file name.
    private func bookTitle() -> String {
        let project = try? managedObjectContext?.fetch(Project.fetchRequest()).first
        return ProjectMetadata.effectiveTitle(
            stored: (project ?? nil)?.title,
            documentName: displayName
        )
    }

    /// The subtitle for the title page, or "" when the user hasn't set one (in
    /// which case the title page simply omits it).
    private func subtitle() -> String {
        let project = try? managedObjectContext?.fetch(Project.fetchRequest()).first
        return ProjectMetadata.effectiveSubtitle(stored: (project ?? nil)?.subtitle)
    }

    /// The author for the title page: the project's author if set, otherwise the
    /// macOS account name.
    private func author() -> String {
        let project = try? managedObjectContext?.fetch(Project.fetchRequest()).first
        return ProjectMetadata.effectiveAuthor(stored: (project ?? nil)?.author)
    }

    /// Chapters to print for the whole project, in order, with empty chapters
    /// skipped so they don't produce blank pages. Falls back to a single
    /// placeholder page if there is nothing to print at all.
    private func printableProjectChapters() -> [PrintableChapter] {
        let chapters = orderedChapters()
            .map { PrintableChapter(title: $0.title, bodyData: $0.bodyData) }
            .filter(\.hasContent)
        return chapters.isEmpty
            ? [PrintableChapter(title: displayName, bodyData: nil)]
            : chapters
    }

    /// AppKit's standard Print command enters through this method. Without
    /// this override NSDocument reports that the application does not support
    /// printing, even if the document has other custom print actions.
    override func printOperation(
        withSettings printSettings: [NSPrintInfo.AttributeKey: Any]
    ) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)

        return ManuscriptPrinter.printOperation(
            chapters: printableProjectChapters(),
            jobTitle: displayName,
            bookTitle: bookTitle(),
            subtitle: subtitle(),
            author: author(),
            includeTitlePage: true,
            printInfo: info
        )
    }

    @objc func printProject(_ sender: Any?) {
        runPrint(chapters: printableProjectChapters(), jobTitle: displayName, includeTitlePage: true)
    }

    @objc func printChapter(_ sender: Any?) {
        guard let context = managedObjectContext,
              let id = currentChapterID,
              let chapter = try? context.existingObject(with: id) as? Chapter else {
            NSSound.beep()
            return
        }
        runPrint(chapters: [PrintableChapter(title: chapter.title, bodyData: chapter.bodyData)],
                 jobTitle: chapter.title ?? displayName)
    }

    // MARK: - Plain text export

    @objc func exportProjectAsPlainText(_ sender: Any?) {
        let chapters = orderedChapters().map {
            PrintableChapter(title: $0.title, bodyData: $0.bodyData)
        }
        let text = PlainTextExporter.plainText(for: chapters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            (displayName as NSString).deletingPathExtension.isEmpty
            ? "Untitled"
            : (displayName as NSString).deletingPathExtension

        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.presentError(error)
            }
        }

        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    // MARK: - Word export

    @objc func exportWordChapters(_ sender: Any?) {
        let chapters = orderedChapters().map {
            PrintableChapter(title: $0.title, bodyData: $0.bodyData)
        }
        guard chapters.contains(where: \.hasContent) else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for the Word chapter documents."

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                let urls = try WordDocumentExporter.exportChapters(chapters, to: folder)
                self?.presentWordExportSummary(count: urls.count, folder: folder)
            } catch {
                self?.presentError(error)
            }
        }

        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func presentWordExportSummary(count: Int, folder: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = count == 1 ? "Exported 1 Word chapter." : "Exported \(count) Word chapters."
        alert.informativeText = folder.path
        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Word import

    /// Opens a multi-select panel for `.docx` files and imports each one as a
    /// new chapter, appended in the order chosen. Failures are per file and
    /// non-fatal — a corrupt or unreadable file is skipped and reported in a
    /// single summary alert once every file has been tried.
    @objc func importWordChapters(_ sender: Any?) {
        guard let context = managedObjectContext else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose one or more Word documents to import as chapters."

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.importWordDocuments(panel.urls, into: context)
        }

        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func importWordDocuments(_ urls: [URL], into context: NSManagedObjectContext) {
        guard !urls.isEmpty,
              let project = try? context.fetch(Project.fetchRequest()).first
        else {
            NSSound.beep()
            return
        }

        let maximumImageWidth = PagedEditorLayout.letter.contentWidth
        var nextSortIndex = (project.orderedChapters.last?.sortIndex ?? -1) + 1
        var importedCount = 0
        var failures: [(name: String, message: String)] = []

        for url in urls {
            do {
                let body = try WordDocumentImporter.importChapterBody(
                    from: url, maximumImageWidth: maximumImageWidth
                )
                let styledBody = ProjectFontStyler.restyled(body, familyName: project.bodyFontFamily)
                let chapter = Chapter(context: context)
                chapter.id = UUID()
                chapter.title = url.deletingPathExtension().lastPathComponent
                chapter.createdAt = Date()
                chapter.sortIndex = nextSortIndex
                chapter.project = project
                chapter.bodyData = RichTextCodec.encode(styledBody)
                nextSortIndex += 1
                importedCount += 1
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }

        presentImportSummary(importedCount: importedCount, totalCount: urls.count, failures: failures)
    }

    private func presentImportSummary(
        importedCount: Int,
        totalCount: Int,
        failures: [(name: String, message: String)]
    ) {
        let alert = NSAlert()
        if failures.isEmpty {
            alert.messageText = importedCount == 1 ? "Imported 1 chapter." : "Imported \(importedCount) chapters."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Imported \(importedCount) of \(totalCount) chapter\(totalCount == 1 ? "" : "s")."
            alert.informativeText = failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")
            alert.alertStyle = .warning
        }

        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func runPrint(chapters: [PrintableChapter], jobTitle: String, includeTitlePage: Bool = false) {
        let operation = ManuscriptPrinter.printOperation(
            chapters: chapters,
            jobTitle: jobTitle,
            bookTitle: bookTitle(),
            subtitle: subtitle(),
            author: author(),
            includeTitlePage: includeTitlePage,
            printInfo: printInfo
        )
        if let window = windowControllers.first?.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
