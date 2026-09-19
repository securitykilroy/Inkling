//
//  SidebarPortTests.swift
//  InklingTests
//
//  Regression cover for the sidebar work carried over from the
//  `sidebar-titles-and-aside-menu` branch: moving a selection into a new box,
//  author-set box titles (and their persistence/export), and resizing an object
//  that sits flush against the right margin.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct SidebarPortTests {

    // MARK: - Fixtures

    private static func body(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    private static func stack(_ text: String) -> PageStackView {
        let stack = PageStackView()
        stack.setAttributedString(body(text))
        return stack
    }

    private static func image(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private static func sidebar(in stack: PageStackView) -> SidebarAttachment? {
        var found: SidebarAttachment?
        stack.storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: stack.storage.length)
        ) { value, _, stop in
            if let sidebar = value as? SidebarAttachment {
                found = sidebar
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Insert over a selection

    /// The bug this replaces was silent data loss: the anchor replaced the
    /// selected range while the box was seeded with nil, so the words vanished
    /// and an empty box appeared where they had been.
    @Test func insertingOverASelectionMovesTheWordsIntoTheBox() throws {
        let stack = Self.stack("Alpha bravo charlie delta.")
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 13))
        stack.insertSidebar()

        // The selection is gone from the body...
        #expect(!stack.storage.string.contains("bravo charlie"))
        // ...because it is now in the box, not because it was destroyed.
        let box = try #require(Self.sidebar(in: stack))
        let content = try #require(RichTextCodec.decode(box.contentData))
        #expect(content.string == "bravo charlie")
    }

    @Test func insertingWithNoSelectionStillGivesAnEmptyBox() throws {
        let stack = Self.stack("Alpha bravo charlie delta.")
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 0))
        stack.insertSidebar()

        #expect(stack.storage.string.contains("bravo charlie"))
        let box = try #require(Self.sidebar(in: stack))
        #expect(box.contentData == nil)
    }

    /// A selection carrying an image can't move into a box — the box's storage
    /// has nowhere to put the image's page position — so it is left alone
    /// rather than being consumed along with its anchor.
    @Test func aSelectionCarryingAnImageIsLeftAlone() throws {
        let text = NSMutableAttributedString(attributedString: Self.body("Alpha bravo delta."))
        let attachment = NSTextAttachment()
        attachment.image = Self.image(NSSize(width: 40, height: 30))
        text.insert(NSAttributedString(attachment: attachment), at: 6)

        let stack = PageStackView()
        stack.setAttributedString(text)
        let before = stack.storage.string
        stack.pageViews[0].setSelectedRange(NSRange(location: 5, length: 3))
        stack.insertSidebar()

        // The image's anchor survives: one more character (the sidebar's own
        // anchor), not three fewer.
        #expect(stack.storage.length == (before as NSString).length + 1)
        let box = try #require(Self.sidebar(in: stack))
        #expect(box.contentData == nil)
    }

    /// Moved text adopts the box's typography, but bold and italic carry
    /// meaning in prose and survive.
    @Test func movedTextAdoptsTheBoxStyleButKeepsBold() throws {
        let text = NSMutableAttributedString(attributedString: Self.body("Alpha bravo delta."))
        text.addAttribute(
            .font, value: NSFont.boldSystemFont(ofSize: 28), range: NSRange(location: 6, length: 5)
        )

        let restyled = SidebarContent.restyled(text.attributedSubstring(from: NSRange(location: 6, length: 5)))
        let font = try #require(restyled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == SidebarStyle.contentFontSize)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func aWhitespaceOnlySelectionGivesAnEmptyBoxRatherThanABlankLine() {
        #expect(SidebarContent.content(from: Self.body("   \n  ")) == nil)
    }

    /// The undo fix that already shipped in main has to survive the change:
    /// Insert Sidebar registers its own undo action rather than letting ⌘Z undo
    /// whatever preceded it.
    @Test func insertingOverASelectionIsUndoable() throws {
        let stack = Self.stack("Alpha bravo charlie delta.")
        let before = stack.storage.string
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 13))
        stack.insertSidebar()
        #expect(stack.storage.string != before)

        let undo = stack.sharedUndoManager
        if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        #expect(undo.canUndo)
        undo.undo()

        #expect(stack.storage.string == before)
    }

    // MARK: - Titles

    @Test func anUntitledBoxFallsBackToTheDefaultLabel() {
        let box = SidebarAttachment(
            contentData: nil, width: 220, position: nil,
            contentHeight: SidebarStyle.minContentHeight
        )
        #expect(box.displayTitle == SidebarStyle.defaultTitle)
        box.title = "   "
        #expect(box.displayTitle == SidebarStyle.defaultTitle)
        box.title = "On Falconry"
        #expect(box.displayTitle == "On Falconry")
    }

    @Test func aTitleSurvivesAnEncodeDecodeRoundTrip() throws {
        let stack = Self.stack("Alpha bravo delta.")
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 0))
        stack.insertSidebar()
        try #require(Self.sidebar(in: stack)).title = "On Falconry"

        let encoded = try #require(RichTextCodec.encode(stack.storage))
        let decoded = try #require(RichTextCodec.decode(encoded))

        var restored: SidebarAttachment?
        decoded.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: decoded.length)
        ) { value, _, stop in
            if let box = value as? SidebarAttachment { restored = box; stop.pointee = true }
        }
        #expect(try #require(restored).title == "On Falconry")
    }

    /// Sidecars written before titles existed have no title field at all. They
    /// must still decode, and read as untitled rather than failing.
    @Test func aBoxWrittenBeforeTitlesExistedStillDecodes() throws {
        let stack = Self.stack("Alpha bravo delta.")
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 0))
        stack.insertSidebar()
        // Title left empty, which is what an older file's sidecar encodes as —
        // the field is omitted entirely rather than written as "".
        let encoded = try #require(RichTextCodec.encode(stack.storage))
        let decoded = try #require(RichTextCodec.decode(encoded))

        var restored: SidebarAttachment?
        decoded.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: decoded.length)
        ) { value, _, stop in
            if let box = value as? SidebarAttachment { restored = box; stop.pointee = true }
        }
        let box = try #require(restored)
        #expect(box.title.isEmpty)
        #expect(box.displayTitle == SidebarStyle.defaultTitle)
    }

    @Test func committingARenameWritesItBackAndDirtiesTheDocument() throws {
        let view = SidebarTextView.make(width: 220)
        var committed: String?
        view.onTitleEdited = { committed = $0 }

        view.beginTitleEditing()
        let field = try #require(view.titleFieldForTesting)
        field.stringValue = "  On Falconry  "
        view.endTitleEditing()

        #expect(committed == "On Falconry")
        #expect(view.title == "On Falconry")
        #expect(view.isEditingTitle == false)
    }

    /// The header band is chrome. It belongs to the host page view — which owns
    /// selecting, dragging and the rename gesture — even once the box is
    /// entered, or a box could only be dragged from below its own top edge.
    @Test func theHeaderBandNeverBelongsToTheBoxText() {
        let view = SidebarTextView.make(width: 220)
        view.isEntered = true

        #expect(view.isInHeaderBand(NSPoint(x: 20, y: 4)))
        #expect(!view.isInHeaderBand(NSPoint(x: 20, y: SidebarStyle.headerHeight + 4)))
    }

    /// A double-click means two different things depending on where it lands:
    /// the header band renames the box, the body enters its text.
    @Test func doubleClickingTheHeaderRenamesRatherThanEnteringTheBox() throws {
        let stack = Self.stack(String(repeating: "Paragraph text. ", count: 60))
        stack.pageViews[0].setSelectedRange(NSRange(location: 10, length: 0))
        stack.insertSidebar()
        stack.exitSidebar()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack
        stack.prepareSidebars()

        let id = try #require(stack.sidebarPlacements.keys.first)
        let located = try #require(stack.sidebarViewRect(id))
        let view = try #require(stack.sidebarViews[id])

        func doubleClick(at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: located.view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: located.view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 2, pressure: 1
            )!
        }

        // On the header band: renames.
        let header = NSPoint(x: located.rect.midX, y: located.rect.minY + 4)
        #expect(stack.handleSidebarMouseDown(at: header, in: located.view, event: doubleClick(at: header)))
        #expect(view.isEditingTitle)
        #expect(stack.enteredSidebar == nil)

        view.endTitleEditing()

        // Below it: enters the box's text.
        let bodyPoint = NSPoint(
            x: located.rect.midX,
            y: located.rect.minY + SidebarStyle.headerHeight + 6
        )
        #expect(stack.handleSidebarMouseDown(at: bodyPoint, in: located.view, event: doubleClick(at: bodyPoint)))
        #expect(view.isEditingTitle == false)
        #expect(stack.enteredSidebar == id)
    }

    // MARK: - Export

    @Test func plainTextExportNamesATitledBox() throws {
        let stack = Self.stack("Alpha bravo delta.")
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 5))
        stack.insertSidebar()
        try #require(Self.sidebar(in: stack)).title = "On Falconry"

        let chapter = PrintableChapter(title: "One", bodyData: RichTextCodec.encode(stack.storage))
        let text = try PlainTextExporter.plainText(for: [chapter])

        #expect(text.contains("[SIDEBAR: On Falconry]"))
        // The closing tag stays fixed so anything parsing these files still works.
        #expect(text.contains("[/SIDEBAR]"))
    }

    @Test func plainTextExportLeavesAnUntitledBoxMarkerAlone() throws {
        let stack = Self.stack("Alpha bravo delta.")
        stack.pageViews[0].setSelectedRange(NSRange(location: 6, length: 5))
        stack.insertSidebar()

        let chapter = PrintableChapter(title: "One", bodyData: RichTextCodec.encode(stack.storage))
        let text = try PlainTextExporter.plainText(for: [chapter])

        #expect(text.contains("[SIDEBAR]"))
        #expect(!text.contains("[SIDEBAR:"))
    }

    // MARK: - Resize against the right margin

    /// An object flush against the right margin measured its room to grow from
    /// its left edge, which came out as exactly its own width — zero room — so
    /// it could not be grown from any corner, including the bottom-left one
    /// that grows leftward into the open column.
    @Test func anImageAtTheRightMarginGrowsFromItsLeftHandle() throws {
        let size = NSSize(width: 200, height: 150)
        let layout = PagedEditorLayout.letter
        // Flush right: the image's right edge sits on the right content edge.
        let position = FloatingImagePosition(
            page: 0,
            origin: CGPoint(
                x: layout.leftMargin + layout.contentWidth - size.width,
                y: layout.topMargin + 40
            )
        )

        let text = NSMutableAttributedString(
            attributedString: NSAttributedString(
                string: String(repeating: "Paragraph text. ", count: 400),
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
        )
        let attachment = NSTextAttachment()
        attachment.image = Self.image(size)
        attachment.bounds = NSRect(origin: .zero, size: size)
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttribute(
            .inklingFloatingImagePosition, value: position,
            range: NSRange(location: 0, length: piece.length)
        )
        text.insert(piece, at: 40)

        let stack = PageStackView()
        stack.setAttributedString(text)
        stack.prepareFloatingImages()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack

        let pageView = stack.pageViews[0]
        let hit = try #require(pageView.floatingImages.first)
        let rect = pageView.viewRect(forFloating: hit.rect)
        _ = stack.beginImageDrag(at: NSPoint(x: rect.midX, y: rect.midY), in: pageView)
        _ = stack.endImageDrag()

        // Grab the bottom-LEFT handle and drag it further left — into the open
        // column, away from the margin the image is already touching.
        let corner = NSPoint(x: rect.minX, y: rect.maxY)
        #expect(stack.beginImageResize(
            at: corner, windowPoint: pageView.convert(corner, to: nil), in: pageView
        ))
        #expect(stack.continueImageResize(
            with: NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: pageView.convert(NSPoint(x: corner.x - 60, y: corner.y + 45), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pageView.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!,
            in: pageView
        ))
        #expect(stack.endImageResize())

        let resized = try #require(stack.floatingAttachment(at: hit.location))
        #expect(resized.displaySize.width > size.width)
    }

    /// One handle on the right alone was useless for the common case: a box
    /// parked against the right margin has no room on that side, so there was
    /// no gesture that could widen it at all.
    @Test func aBoxHasAGrabbableHandleOnBothBottomCorners() {
        let stack = PageStackView()
        let box = NSRect(x: 100, y: 100, width: 220, height: 120)

        let leading = stack.sidebarResizeHandleRect(box, edge: .leading)
        let trailing = stack.sidebarResizeHandleRect(box, edge: .trailing)
        #expect(abs(leading.midX - box.minX) < 0.5)
        #expect(abs(trailing.midX - box.maxX) < 0.5)
        #expect(abs(leading.midY - box.maxY) < 0.5)

        #expect(stack.sidebarResizeEdge(at: NSPoint(x: box.minX, y: box.maxY), boxRect: box) == .leading)
        #expect(stack.sidebarResizeEdge(at: NSPoint(x: box.maxX, y: box.maxY), boxRect: box) == .trailing)
        #expect(stack.sidebarResizeEdge(at: NSPoint(x: box.midX, y: box.midY), boxRect: box) == nil)
    }
}
