//
//  UndoRoutingTests.swift
//  InklingTests
//
//  Undo sent the way the menu item sends it — up the responder chain of the
//  real document window, from the place the author's focus is — rather than
//  called on the undo manager directly. This is the route by which undoing a
//  rename used to roll a chapter's text back (`RichTextUndoGuard`).
//

import AppKit
import CoreData
import Testing
@testable import Inkling

@MainActor
struct UndoRoutingTests {

    private func spin(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func find<T: NSView>(
        _ type: T.Type, in view: NSView, where test: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, test(match) { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview, where: test) { return found }
        }
        return nil
    }

    /// What Edit > Undo does: the first responder up the chain that takes
    /// `undo:` gets it. (`NSApp.sendAction` needs an active app, which a test
    /// host isn't.)
    private func sendUndo(in window: NSWindow) {
        let action = Selector(("undo:"))
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) {
                current.perform(action, with: nil)
                return
            }
            responder = current.nextResponder
        }
        Issue.record("nothing in the responder chain handles undo:")
    }

    private func body(of chapter: Chapter) -> String? {
        RichTextCodec.decode(chapter.bodyData)?.string
    }

    @Test func undoFromTheTitleFieldAndTheChapterListKeepsTypedText() throws {
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let undoManager = try #require(context.undoManager)
        NSDocumentController.shared.addDocument(document)
        defer { document.close() }

        undoManager.disableUndoRegistration()
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Project"
        project.createdAt = Date()
        let chapter = Chapter(context: context)
        chapter.id = UUID()
        chapter.title = "Old"
        chapter.sortIndex = 0
        chapter.createdAt = Date()
        chapter.project = project
        chapter.bodyData = RichTextCodec.encode(
            NSAttributedString(string: "Opened.", attributes: [.font: TextStyle.body.font])
        )
        context.processPendingChanges()
        undoManager.enableUndoRegistration()

        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.makeKeyAndOrderFront(nil)
        spin(1.0)
        let root = try #require(window.contentView)
        #expect(window.undoManager === undoManager)

        let list = try #require(find(NSTableView.self, in: root), "chapter list")
        if find(NSTextField.self, in: root, where: { $0.placeholderString == "Chapter Title" }) == nil {
            list.selectRowIndexes([0], byExtendingSelection: false)
            spin(0.8)
        }
        let title = try #require(
            find(NSTextField.self, in: root) { $0.placeholderString == "Chapter Title" }, "title field"
        )
        let page = try #require(find(PageTextView.self, in: root), "chapter editor")

        // Rename in the title field, write in the chapter, back to the title
        // field, Undo.
        #expect(window.makeFirstResponder(title))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("New", replacementRange: fieldEditor.selectedRange())
        spin()
        #expect(chapter.title == "New")

        #expect(window.makeFirstResponder(page))
        page.insertText(" Typed since.", replacementRange: NSRange(location: 7, length: 0))
        spin()
        #expect(body(of: chapter) == "Opened. Typed since.")

        #expect(window.makeFirstResponder(title))
        spin(0.2)
        sendUndo(in: window)
        spin()
        #expect(chapter.title == "Old", "the rename is undone")
        #expect(body(of: chapter) == "Opened. Typed since.", "the writing is not")

        // The same from the chapter list.
        chapter.title = "Third"
        context.processPendingChanges()
        spin(0.2)
        #expect(window.makeFirstResponder(page))
        page.insertText(" More.", replacementRange: NSRange(location: (page.string as NSString).length, length: 0))
        spin()
        #expect(window.makeFirstResponder(list))
        sendUndo(in: window)
        spin()
        #expect(chapter.title == "Old")
        #expect(body(of: chapter) == "Opened. Typed since. More.")
        #expect(page.string == "Opened. Typed since. More.")
    }

    /// A second Undo in the title field, after the first has reverted a
    /// rename, must not leave the field showing a name the chapter doesn't have.
    @Test func aSecondUndoInTheTitleFieldNeverShowsATitleTheChapterDoesNotHave() throws {
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let undoManager = try #require(context.undoManager)
        NSDocumentController.shared.addDocument(document)
        defer { document.close() }

        undoManager.disableUndoRegistration()
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Project"
        project.createdAt = Date()
        let chapter = Chapter(context: context)
        chapter.id = UUID()
        chapter.title = "Old"
        chapter.sortIndex = 0
        chapter.createdAt = Date()
        chapter.project = project
        chapter.bodyData = RichTextCodec.encode(
            NSAttributedString(string: "Opened.", attributes: [.font: TextStyle.body.font])
        )
        context.processPendingChanges()
        undoManager.enableUndoRegistration()

        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.makeKeyAndOrderFront(nil)
        spin(1.0)
        let root = try #require(window.contentView)

        let list = try #require(find(NSTableView.self, in: root), "chapter list")
        if find(NSTextField.self, in: root, where: { $0.placeholderString == "Chapter Title" }) == nil {
            list.selectRowIndexes([0], byExtendingSelection: false)
            spin(0.8)
        }
        let title = try #require(
            find(NSTextField.self, in: root) { $0.placeholderString == "Chapter Title" }, "title field"
        )

        #expect(window.makeFirstResponder(title))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("New", replacementRange: fieldEditor.selectedRange())
        spin()
        #expect(chapter.title == "New")

        sendUndo(in: window)
        spin()
        #expect(chapter.title == "Old")
        #expect(title.stringValue == "Old")

        sendUndo(in: window)
        spin()
        // Nothing is left to undo; the field must not invent a title.
        #expect(chapter.title == "Old")
        #expect(title.stringValue == "Old")

        // Redo puts the rename back, in the chapter and in the field alike.
        let redo = Selector(("redo:"))
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: redo) { responder = current.nextResponder }
        responder?.perform(redo, with: nil)
        spin()
        #expect(chapter.title == "New")
        #expect(title.stringValue == (chapter.title ?? ""), "the field shows the stored title")
    }

    /// An open project window with one chapter selected.
    private func openWindow() throws -> (InklingDocument, NSWindow, Chapter, UndoManager) {
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let undoManager = try #require(context.undoManager)
        NSDocumentController.shared.addDocument(document)

        undoManager.disableUndoRegistration()
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Project"
        project.createdAt = Date()
        let chapter = Chapter(context: context)
        chapter.id = UUID()
        chapter.title = "Old"
        chapter.sortIndex = 0
        chapter.createdAt = Date()
        chapter.project = project
        chapter.bodyData = RichTextCodec.encode(
            NSAttributedString(string: "Opened.", attributes: [.font: TextStyle.body.font])
        )
        context.processPendingChanges()
        undoManager.enableUndoRegistration()

        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        window.makeKeyAndOrderFront(nil)
        spin(1.0)
        let root = try #require(window.contentView)
        if find(NSTextField.self, in: root, where: { $0.placeholderString == "Chapter Title" }) == nil,
           let list = find(NSTableView.self, in: root) {
            list.selectRowIndexes([0], byExtendingSelection: false)
            spin(0.8)
        }
        return (document, window, chapter, undoManager)
    }

    private func titleField(in window: NSWindow) -> NSTextField? {
        window.contentView.flatMap {
            find(NSTextField.self, in: $0) { $0.placeholderString == "Chapter Title" }
        }
    }

    /// A rename typed in the title field is an undo step of its own, named
    /// for what it is, and the field follows the stored title through Undo
    /// and Redo. (That later keystrokes add no further steps is checked on
    /// `renameChapter` itself, in `DataIntegrityFixTests`: a test runs inside
    /// one event, so it can't tell one undo group from several.)
    @Test func renamingInTheTitleFieldIsAnUndoStepOfItsOwn() throws {
        let (document, window, chapter, undoManager) = try openWindow()
        defer { document.close() }
        let title = try #require(titleField(in: window))

        #expect(window.makeFirstResponder(title))
        let fieldEditor = try #require(window.firstResponder as? NSTextView)
        fieldEditor.selectAll(nil)
        for character in ["N", "e", "w"] {
            fieldEditor.insertText(character, replacementRange: fieldEditor.selectedRange())
            spin(0.15)
        }
        #expect(chapter.title == "New")
        #expect(undoManager.undoActionName == "Rename Chapter")
        #expect(document.isDocumentEdited)

        sendUndo(in: window)
        spin()
        #expect(chapter.title == "Old")
        #expect(title.stringValue == "Old")
        #expect(!undoManager.canUndo)

        undoManager.redo()
        spin()
        #expect(chapter.title == "New")
        #expect(title.stringValue == "New")

        // Typing after an Undo is a new rename: it registers a step (which
        // is what empties Redo) instead of riding on the one just undone.
        undoManager.undo()
        spin()
        #expect(undoManager.canRedo)
        fieldEditor.insertText("!", replacementRange: NSRange(location: 3, length: 0))
        spin(0.15)
        #expect(chapter.title == "Old!")
        #expect(!undoManager.canRedo)
        #expect(undoManager.undoActionName == "Rename Chapter")
    }

    /// Undoing New Chapter removes the chapter; its editor must go with it
    /// rather than stay on screen, editable, over a chapter that is gone.
    @Test func undoingNewChapterClosesItsEditor() throws {
        let (document, window, _, undoManager) = try openWindow()
        defer { document.close() }
        let root = try #require(window.contentView)

        document.newChapter(nil)
        spin(0.8)
        #expect(titleField(in: window)?.stringValue == "Untitled Chapter")

        undoManager.undo()
        spin(0.8)
        #expect(titleField(in: window) == nil, "no title field for the removed chapter")
        #expect(find(PageTextView.self, in: root) == nil, "and no editor")

        // Redo brings the chapter back; nothing is selected until the author picks it.
        undoManager.redo()
        spin(0.8)
        #expect(document.managedObjectContext?.registeredObjects.compactMap { $0 as? Chapter }
            .filter { !$0.isDeleted }.count == 2)
    }
}
