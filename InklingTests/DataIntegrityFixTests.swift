//
//  DataIntegrityFixTests.swift
//  InklingTests
//
//  Three ways an author's work could change without their doing anything:
//  sidecar offsets drifting off their images, Undo rolling a chapter's text
//  back, and opening a chapter rewriting it. (The third is mostly covered in
//  `PageStackViewTests`, beside the tests it changed.)
//

import AppKit
import CoreData
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Inkling

@MainActor
struct DataIntegrityFixTests {

    private static func png() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private static func imageAttachment() -> NSTextAttachment {
        let data = png()
        return RichTextImageInserter.makeAttachment(
            for: NSImage(data: data)!, sourceData: data, contentType: .png,
            filename: "pic.png", maximumWidth: 468
        )
    }

    private static let sidebarWords = "Words the author wrote in the box"

    /// Text with `prefix` ahead of a positioned, captioned image, a titled
    /// sidebar, and a callout — everything the sidecars describe.
    private static func chapter(prefix: String) throws -> (
        text: NSMutableAttributedString, image: Int, sidebar: Int, callout: NSRange
    ) {
        let font: [NSAttributedString.Key: Any] = [.font: TextStyle.body.font]
        let body = NSMutableAttributedString(string: prefix + " ", attributes: font)
        let image = body.length
        body.append(NSAttributedString(attachment: imageAttachment()))
        body.addAttribute(.inklingImageCaption, value: "My caption",
                          range: NSRange(location: image, length: 1))
        body.addAttribute(.inklingFloatingImagePosition,
                          value: FloatingImagePosition(page: 0, origin: CGPoint(x: 300, y: 300)),
                          range: NSRange(location: image, length: 1))
        body.append(NSAttributedString(string: " middle ", attributes: font))

        let content = try #require(RichTextCodec.encode(NSAttributedString(
            string: sidebarWords, attributes: [.font: SidebarStyle.contentFont]
        )))
        let box = SidebarAttachment(
            contentData: content, width: 220,
            position: FloatingImagePosition(page: 0, origin: CGPoint(x: 320, y: 500)),
            contentHeight: 40
        )
        box.title = "Aside"
        let sidebar = body.length
        let anchor = NSMutableAttributedString(attachment: box)
        anchor.addAttributes(font, range: NSRange(location: 0, length: 1))
        body.append(anchor)
        body.append(NSAttributedString(string: " end.\n", attributes: font))

        let callout = NSRange(location: body.length, length: 18)
        body.append(NSAttributedString(string: "A note paragraph.\n", attributes: font))
        CalloutStyling.apply(.note, to: body, range: callout)
        body.append(NSAttributedString(string: "After the note.", attributes: font))
        return (body, image, sidebar, callout)
    }

    /// Everything the sidecars restore, read back off decoded text.
    private struct Restored {
        var caption: String?
        var position: FloatingImagePosition?
        var imageSize: NSSize = .zero
        var sidebarTitles: [String] = []
        var sidebarTexts: [String] = []
        var calloutTexts: [String] = []

        init(_ text: NSAttributedString) {
            let whole = NSRange(location: 0, length: text.length)
            text.enumerateAttribute(.attachment, in: whole) { value, range, _ in
                if let sidebar = value as? SidebarAttachment {
                    sidebarTitles.append(sidebar.title)
                    sidebarTexts.append(RichTextCodec.decode(sidebar.contentData)?.string ?? "")
                } else if let image = value as? NSTextAttachment {
                    imageSize = image.bounds.size
                    caption = text.attribute(.inklingImageCaption, at: range.location, effectiveRange: nil) as? String
                    position = text.attribute(
                        .inklingFloatingImagePosition, at: range.location, effectiveRange: nil
                    ) as? FloatingImagePosition
                }
            }
            text.enumerateAttribute(.inklingCallout, in: whole) { value, range, _ in
                if value != nil { calloutTexts.append((text.string as NSString).substring(with: range)) }
            }
        }
    }

    private static func expectIntact(_ restored: Restored, _ comment: Comment) {
        #expect(restored.caption == "My caption", comment)
        #expect(restored.position == FloatingImagePosition(page: 0, origin: CGPoint(x: 300, y: 300)), comment)
        #expect(restored.imageSize == NSSize(width: 200, height: 100), comment)
        #expect(restored.sidebarTitles == ["Aside"], comment)
        #expect(restored.sidebarTexts == [sidebarWords], comment)
        #expect(restored.calloutTexts == ["A note paragraph.\n"], comment)
    }

    // MARK: - 1. Sidecar offsets

    /// Each of these is a character the RTF writer and reader between them
    /// drop or merge. One of them ahead of an image used to move every later
    /// sidecar offset, so the image lost its size, position and caption, the
    /// callout covered the wrong characters, and the sidebar lost its text.
    @Test(arguments: [
        "Pasted one\r\nPasted two.",
        "Two\r\nline\r\nendings.",
        "A NUL\u{0}in the text.",
        "Mojibake \u{fffd} here.",
        "A stray \u{fffc} object character.",
    ])
    func charactersRTFDropsDoNotMoveTheSidecars(prefix: String) throws {
        let chapter = try Self.chapter(prefix: prefix)
        let saved = try #require(RichTextCodec.encode(chapter.text))
        let reopened = try #require(RichTextCodec.decode(saved))
        Self.expectIntact(Restored(reopened), "after one save")

        // And it stays put through the editor and a second save, which is
        // where the sidebar's text used to disappear for good.
        let stack = PageStackView()
        stack.setAttributedString(reopened)
        stack.prepareFloatingImages(joiningImageOnlyLines: false)
        stack.prepareSidebars()
        let resaved = try #require(RichTextCodec.encode(stack.storage))
        #expect(TextStatistics.wordCount(inRTF: resaved) == TextStatistics.wordCount(inRTF: saved))
        let again = Restored(try #require(RichTextCodec.decode(resaved)))
        #expect(again.sidebarTexts == [Self.sidebarWords])
        #expect(again.caption == "My caption")
    }

    @Test func storableLeavesOrdinaryTextUncopied() {
        let text = NSMutableAttributedString(string: "Plain\ntext\rwith a lone return. ")
        text.append(NSAttributedString(attachment: Self.imageAttachment()))
        #expect(RichTextCodec.storable(text) === text)
    }

    @Test func storableRemovesOnlyWhatRTFWouldDrop() {
        let text = NSMutableAttributedString(string: "a\r\nb\rc\u{0}d\u{fffd}e\u{fffc}f")
        text.append(NSAttributedString(attachment: Self.imageAttachment()))
        #expect(RichTextCodec.storable(text).string == "a\nb\rcdef\u{fffc}")
    }

    /// A file saved before `storable` existed, with its offsets already wrong.
    /// It is built by hand, the way the old encoder wrote it: RTFD of the raw
    /// text, and sidecars measured against the raw text.
    @Test func aFileSavedWithDriftedOffsetsIsRepairedOnOpen() throws {
        let chapter = try Self.chapter(prefix: "Pasted one\r\nPasted two.\r\nPasted three.")
        let text = chapter.text
        let wrapper = try #require(text.rtfdFileWrapper(
            from: NSRange(location: 0, length: text.length), documentAttributes: [:]
        ))
        let box = try #require(text.attribute(.attachment, at: chapter.sidebar, effectiveRange: nil) as? SidebarAttachment)
        func add(_ object: Any, _ name: String) throws {
            wrapper.addRegularFile(
                withContents: try JSONSerialization.data(withJSONObject: object), preferredFilename: name
            )
        }
        try add([[
            "location": chapter.image, "width": 200, "height": 100,
            "page": 0, "originX": 300, "originY": 300, "caption": "My caption",
        ]], "__inkling_attachment_sizes.json")
        try add([[
            "location": chapter.sidebar, "width": 220, "contentHeight": 40,
            "page": 0, "originX": 320, "originY": 500, "title": "Aside",
            "content": try #require(box.contentData).base64EncodedString(),
        ]], "__inkling_sidebars.json")
        try add([[
            "location": chapter.callout.location, "length": chapter.callout.length, "kind": "note",
        ]], "__inkling_callouts.json")
        let legacy = try #require(wrapper.serializedRepresentation)

        let reopened = try #require(RichTextCodec.decode(legacy))
        #expect(reopened.length == text.length - 2, "the two \\r really are gone")
        Self.expectIntact(Restored(reopened), "repaired on open")
    }

    @Test func alignmentIsLeftAloneWhenEveryRecordLandsOnAnAttachment() {
        #expect(RichTextCodec.alignedLocations(of: [4, 9], toAttachmentsAt: [4, 9, 20]) == nil)
        #expect(RichTextCodec.alignedLocations(of: [], toAttachmentsAt: [3]) == nil)
    }

    @Test func driftedRecordsFindTheirAttachmentsInOrder() {
        // One character lost before the first attachment, another before the third.
        #expect(RichTextCodec.alignedLocations(of: [10, 20, 30], toAttachmentsAt: [9, 19, 28])
            == [10: 9, 20: 19, 30: 28])
        // An attachment with no record of its own is passed over, not claimed.
        #expect(RichTextCodec.alignedLocations(of: [10, 30], toAttachmentsAt: [9, 15, 29])
            == [10: 9, 30: 29])
        // Nothing at or before a record's place: it is left unmatched.
        #expect(RichTextCodec.alignedLocations(of: [2], toAttachmentsAt: [9]) == [:])
    }

    /// A sidebar record whose anchor can't be found holds the only copy of
    /// the box's text, so it gets a new anchor rather than being dropped.
    @Test func aSidebarWhoseAnchorIsGoneIsReanchoredNotDropped() throws {
        let text = NSAttributedString(string: "No attachment anywhere in this text.",
                                      attributes: [.font: TextStyle.body.font])
        let wrapper = try #require(text.rtfdFileWrapper(
            from: NSRange(location: 0, length: text.length), documentAttributes: [:]
        ))
        let content = try #require(RichTextCodec.encode(NSAttributedString(string: Self.sidebarWords)))
        wrapper.addRegularFile(
            withContents: try JSONSerialization.data(withJSONObject: [[
                "location": 500, "width": 220, "contentHeight": 40,
                "content": content.base64EncodedString(), "title": "Aside",
            ]]),
            preferredFilename: "__inkling_sidebars.json"
        )
        let reopened = try #require(RichTextCodec.decode(try #require(wrapper.serializedRepresentation)))
        let restored = Restored(reopened)
        #expect(restored.sidebarTexts == [Self.sidebarWords])
        #expect(reopened.string == text.string + "\u{fffc}")
    }

    @Test func pastedWindowsLineEndingsAreNormalisedInTheEditor() throws {
        let stack = PageStackView()
        let page = try #require(stack.pageViews.first)
        page.insertText("before ", replacementRange: NSRange(location: 0, length: 0))
        page.insertText("one\r\ntwo\r\nthree", replacementRange: NSRange(location: 7, length: 0))

        let result = PasteStyling.normalizeLineEndings(in: page, range: NSRange(location: 7, length: 15))

        #expect(stack.storage.string == "before one\ntwo\nthree")
        #expect(result == NSRange(location: 7, length: 13))
        #expect(page.selectedRange() == NSRange(location: 20, length: 0))
    }

    // MARK: - 2. Undo

    private static func document() throws -> (InklingDocument, NSManagedObjectContext, UndoManager) {
        let document = InklingDocument()
        let context = try #require(document.managedObjectContext)
        let undoManager = try #require(context.undoManager)
        NSDocumentController.shared.addDocument(document)
        return (document, context, undoManager)
    }

    private static func chapter(in context: NSManagedObjectContext, undoManager: UndoManager) -> Chapter {
        let chapter = Chapter(context: context)
        chapter.id = UUID()
        chapter.title = "Old title"
        chapter.sortIndex = 0
        chapter.bodyData = Data("as opened".utf8)
        context.processPendingChanges()
        undoManager.removeAllActions()
        return chapter
    }

    /// Core Data undoes an edit by restoring the whole object as it was then.
    /// Typing is kept off its undo stack, so undoing an earlier rename used to
    /// put back the body from the time of the rename.
    @Test func undoingARenameDoesNotRollBackWhatWasTypedSince() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let chapter = Self.chapter(in: context, undoManager: undoManager)

        chapter.title = "New title"
        context.processPendingChanges()
        assignRichTextIfChanged(chapter, \.bodyData, Data("an hour of typing".utf8))

        undoManager.undo()
        context.processPendingChanges()
        #expect(chapter.title == "Old title", "the rename is still undone")
        #expect(chapter.bodyData == Data("an hour of typing".utf8))

        undoManager.redo()
        context.processPendingChanges()
        #expect(chapter.title == "New title")
        #expect(chapter.bodyData == Data("an hour of typing".utf8))

        // And the guard's own write-back must not have become an undo step.
        undoManager.undo()
        context.processPendingChanges()
        #expect(chapter.title == "Old title")
        #expect(chapter.bodyData == Data("an hour of typing".utf8))
        #expect(!undoManager.canUndo)
    }

    @Test func undoingAReorderDoesNotRollBackWhatWasTypedSince() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let chapter = Self.chapter(in: context, undoManager: undoManager)

        chapter.sortIndex = 5
        context.processPendingChanges()
        assignRichTextIfChanged(chapter, \.bodyData, Data("typed after the move".utf8))
        assignRichTextIfChanged(chapter, \.notesData, Data("notes too".utf8))

        undoManager.undo()
        context.processPendingChanges()
        #expect(chapter.sortIndex == 0)
        #expect(chapter.bodyData == Data("typed after the move".utf8))
        #expect(chapter.notesData == Data("notes too".utf8))
    }

    /// The guard must not get in the way of the undo that matters most: a
    /// deleted chapter comes back, with the text it had when it was deleted.
    @Test func undoingADeleteStillBringsTheChapterBackWithItsLatestText() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let chapter = Self.chapter(in: context, undoManager: undoManager)
        let id = try #require(chapter.id)
        assignRichTextIfChanged(chapter, \.bodyData, Data("typed before deleting".utf8))

        context.delete(chapter)
        context.processPendingChanges()
        #expect(try context.fetch(Chapter.fetchRequest()).isEmpty)

        undoManager.undo()
        context.processPendingChanges()
        let restored = try #require(try context.fetch(Chapter.fetchRequest()).first)
        #expect(restored.id == id)
        #expect(restored.bodyData == Data("typed before deleting".utf8))
    }

    /// A font change restyles every blob and records the family beside them,
    /// all outside undo. Undoing some earlier edit to the project must not
    /// put the old family back under text that is now in the new one.
    @Test func undoingAnEarlierProjectEditDoesNotRevertTheFontFamily() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let project = Project(context: context)
        project.id = UUID()
        project.title = "Old"
        context.processPendingChanges()
        undoManager.removeAllActions()

        project.title = "New"
        context.processPendingChanges()
        assignOutsideUndoIfChanged(project, \.bodyFontFamily, "Georgia")
        #expect(document.isDocumentEdited)

        undoManager.undo()
        context.processPendingChanges()
        #expect(project.title == "Old")
        #expect(project.bodyFontFamily == "Georgia")
    }

    // MARK: - Replace All's own undo

    private static func replaceAllChanges(_ chapters: [Chapter], to new: String) -> [RichTextChange] {
        chapters.map {
            RichTextChange(object: $0, key: "bodyData", from: $0.bodyData, to: Data(new.utf8))
        }
    }

    @Test func replaceAllIsOneUndoableStepThatRedoes() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let first = Self.chapter(in: context, undoManager: undoManager)
        let second = Self.chapter(in: context, undoManager: undoManager)

        applyRichTextChanges(Self.replaceAllChanges([first, second], to: "replaced"),
                             actionName: "Replace All", in: context)
        #expect(first.bodyData == Data("replaced".utf8))
        #expect(second.bodyData == Data("replaced".utf8))
        #expect(undoManager.undoActionName == "Replace All")
        #expect(document.isDocumentEdited)

        undoManager.undo()
        context.processPendingChanges()
        #expect(first.bodyData == Data("as opened".utf8))
        #expect(second.bodyData == Data("as opened".utf8))
        #expect(!undoManager.canUndo)

        undoManager.redo()
        context.processPendingChanges()
        #expect(first.bodyData == Data("replaced".utf8))
        #expect(second.bodyData == Data("replaced".utf8))

        undoManager.undo()
        context.processPendingChanges()
        #expect(first.bodyData == Data("as opened".utf8))
    }

    /// The point of the explicit undo: a chapter typed in after Replace All
    /// keeps what was typed; the untouched one is restored. Redo can't reach
    /// the skipped chapter either.
    @Test func undoingReplaceAllLeavesAChapterEditedSinceAlone() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let typedIn = Self.chapter(in: context, undoManager: undoManager)
        let untouched = Self.chapter(in: context, undoManager: undoManager)

        applyRichTextChanges(Self.replaceAllChanges([typedIn, untouched], to: "replaced"),
                             actionName: "Replace All", in: context)
        assignRichTextIfChanged(typedIn, \.bodyData, Data("replaced, then more typing".utf8))

        undoManager.undo()
        context.processPendingChanges()
        #expect(typedIn.bodyData == Data("replaced, then more typing".utf8))
        #expect(untouched.bodyData == Data("as opened".utf8))

        undoManager.redo()
        context.processPendingChanges()
        #expect(typedIn.bodyData == Data("replaced, then more typing".utf8))
        #expect(untouched.bodyData == Data("replaced".utf8))
    }

    /// Skipping a chapter is reported, with the count, on undo and on redo;
    /// an undo that restores everything reports nothing.
    @Test func undoingReplaceAllSaysHowManyChaptersItLeftAlone() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let typedIn = Self.chapter(in: context, undoManager: undoManager)
        let untouched = Self.chapter(in: context, undoManager: undoManager)
        var notices: [RichTextUndoNotice] = []

        applyRichTextChanges(Self.replaceAllChanges([typedIn, untouched], to: "replaced"),
                             actionName: "Replace All", in: context) { notices.append($0) }
        #expect(notices.isEmpty)

        undoManager.undo()
        context.processPendingChanges()
        #expect(notices.isEmpty, "nothing was skipped")
        undoManager.redo()
        context.processPendingChanges()
        #expect(notices.isEmpty)

        assignRichTextIfChanged(typedIn, \.bodyData, Data("replaced, then more typing".utf8))
        undoManager.undo()
        context.processPendingChanges()
        #expect(notices == [RichTextUndoNotice(skipped: 1, actionName: "Replace All", isRedo: false)])
        #expect(notices.first?.message == "Undo Replace All left 1 chapter as it is.")
        #expect(untouched.bodyData == Data("as opened".utf8))

        // The skipped chapter is no longer part of the step, so redoing it
        // has nothing to skip; a chapter edited after the undo is.
        assignRichTextIfChanged(untouched, \.bodyData, Data("as opened, then edited".utf8))
        undoManager.redo()
        context.processPendingChanges()
        #expect(notices.last == RichTextUndoNotice(skipped: 1, actionName: "Replace All", isRedo: true))
        #expect(notices.count == 2)
        #expect(untouched.bodyData == Data("as opened, then edited".utf8))
        #expect(typedIn.bodyData == Data("replaced, then more typing".utf8))
    }

    @Test func skippedUndoNoticeCountsChapters() {
        let two = RichTextUndoNotice(skipped: 2, actionName: "Replace All", isRedo: false)
        #expect(two.message == "Undo Replace All left 2 chapters as they are.")
        #expect(two.explanation.hasPrefix("2 chapters were changed after Replace All"))
        let redo = RichTextUndoNotice(skipped: 1, actionName: "Replace All", isRedo: true)
        #expect(redo.message == "Redo Replace All left 1 chapter as it is.")
    }

    /// Mixed with Core Data's own undo: a rename after Replace All undoes
    /// first and leaves the replaced text alone, then Replace All undoes.
    @Test func replaceAllUndoInterleavesWithARename() throws {
        let (document, context, undoManager) = try Self.document()
        defer { NSDocumentController.shared.removeDocument(document) }
        let chapter = Self.chapter(in: context, undoManager: undoManager)
        // Two separate steps, as two user events are in the app. Left on,
        // event grouping would wrap both in one group here: no run loop turns.
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        applyRichTextChanges(Self.replaceAllChanges([chapter], to: "replaced"),
                             actionName: "Replace All", in: context)
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
        chapter.title = "New title"
        context.processPendingChanges()
        undoManager.endUndoGrouping()

        undoManager.undo()
        context.processPendingChanges()
        #expect(chapter.title == "Old title")
        #expect(chapter.bodyData == Data("replaced".utf8))

        undoManager.undo()
        context.processPendingChanges()
        #expect(chapter.bodyData == Data("as opened".utf8))
        #expect(chapter.title == "Old title")
    }

    // MARK: - Callouts in a file saved with drifted offsets

    @Test func aRangeAlreadyOnParagraphBoundariesIsUnchanged() {
        let text = "One.\nTwo is the note.\nThree.\n\nFive." as NSString
        #expect(RichTextCodec.wholeParagraphs(near: NSRange(location: 5, length: 17), in: text)
            == NSRange(location: 5, length: 17))
        #expect(RichTextCodec.wholeParagraphs(near: NSRange(location: 5, length: 24), in: text)
            == NSRange(location: 5, length: 24))
        // The last paragraph, with no newline after it.
        #expect(RichTextCodec.wholeParagraphs(near: NSRange(location: 30, length: 5), in: text)
            == NSRange(location: 30, length: 5))
    }

    @Test func aShiftedRangeSnapsBackToItsParagraphs() {
        let text = "One.\nTwo is the note.\nThree.\n\nFive." as NSString
        // Shifted two along: tail of "Two…" plus the head of "Three."
        #expect(RichTextCodec.wholeParagraphs(near: NSRange(location: 7, length: 17), in: text)
            == NSRange(location: 5, length: 17))
        // Entirely inside one paragraph.
        #expect(RichTextCodec.wholeParagraphs(near: NSRange(location: 8, length: 4), in: text)
            == NSRange(location: 5, length: 17))
    }

    /// No attachment anywhere, so `realign` has nothing to go on: two lost
    /// "\r" ahead of a callout used to leave it two characters along.
    @Test func aDriftedCalloutWithNoAttachmentToAlignByIsRestoredToItsParagraph() throws {
        let font: [NSAttributedString.Key: Any] = [.font: TextStyle.body.font]
        let raw = NSMutableAttributedString(
            string: "Pasted one\r\nPasted two.\r\nA note paragraph.\nAfter the note.", attributes: font
        )
        let callout = (raw.string as NSString).range(of: "A note paragraph.\n")
        let wrapper = try #require(raw.rtfdFileWrapper(
            from: NSRange(location: 0, length: raw.length), documentAttributes: [:]
        ))
        wrapper.addRegularFile(
            withContents: try JSONSerialization.data(withJSONObject: [[
                "location": callout.location, "length": callout.length, "kind": "note",
            ]]),
            preferredFilename: "__inkling_callouts.json"
        )
        let reopened = try #require(RichTextCodec.decode(try #require(wrapper.serializedRepresentation)))
        #expect(Restored(reopened).calloutTexts == ["A note paragraph.\n"])
    }

    // MARK: - 3. Opening a chapter

    /// Through the editor's real load path: a heading, an image on its own
    /// line, then body text is exactly as saved after opening.
    @Test func loadingAChapterInTheEditorDoesNotChangeItsText() throws {
        let body = NSMutableAttributedString(
            string: "Chapter One\n", attributes: [.font: TextStyle.title.font]
        )
        body.append(NSAttributedString(attachment: Self.imageAttachment()))
        body.append(NSAttributedString(
            string: "\nFirst paragraph.\n", attributes: [.font: TextStyle.body.font]
        ))
        body.append(NSAttributedString(attachment: Self.imageAttachment()))
        body.append(NSAttributedString(
            string: "\nSecond paragraph.", attributes: [.font: TextStyle.body.font]
        ))
        let saved = try #require(RichTextCodec.encode(body))

        let document = InklingDocument()
        let chapter = Chapter(context: try #require(document.managedObjectContext))
        var stored: Data? = saved
        let editor = RichTextEditor(
            data: Binding(get: { stored }, set: { stored = $0 }),
            documentID: chapter.objectID,
            presentation: .paged
        )
        let coordinator = editor.makeCoordinator()
        let stack = PageStackView()
        coordinator.loadStack(stored, documentID: chapter.objectID, into: stack)

        #expect(stack.storage.string == body.string)
        #expect(stored == saved)
        #expect(ChapterOutline.headings(in: saved).map(\.text) == ["Chapter One"])
    }

    @Test func joinAllJoinsImportedImageParagraphsButNotAcrossHeadings() {
        let body = NSMutableAttributedString(
            string: "Heading\n", attributes: [.font: TextStyle.heading.font]
        )
        body.append(NSAttributedString(attachment: Self.imageAttachment()))
        body.append(NSAttributedString(
            string: "\nIntroduces a figure.\n", attributes: [.font: TextStyle.body.font]
        ))
        body.append(NSAttributedString(attachment: Self.imageAttachment()))
        body.append(NSAttributedString(
            string: "\nNext paragraph.\n\n", attributes: [.font: TextStyle.body.font]
        ))
        body.append(NSAttributedString(attachment: Self.imageAttachment()))
        body.append(NSAttributedString(string: "\nLast.", attributes: [.font: TextStyle.body.font]))

        ImageOnlyLine.joinAll(in: body)

        #expect(body.string
            == "Heading\n\u{fffc}\nIntroduces a figure. \u{fffc}\nNext paragraph.\n\n\u{fffc}\nLast.")
    }
}
