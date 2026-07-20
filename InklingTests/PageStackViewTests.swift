//
//  PageStackViewTests.swift
//  InklingTests
//
//  MILESTONE 0 GATE — docs/per-page-container-editor-plan.md §8.
//
//  The per-page-container rearchitecture only pays off if an *editable* stack of
//  N NSTextViews sharing one NSLayoutManager behaves like one document: text
//  flows page to page, there is a single insertion point, and selection crosses
//  page boundaries. Pagination itself is not in doubt (the printer already does
//  it); selection is. These tests are the go/no-go evidence.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct PageStackViewTests {

    // MARK: - Fixtures

    /// Body text long enough to spill across several pages. Deterministic font
    /// so line heights — and therefore page breaks — don't drift with system
    /// settings.
    private static func filler(paragraphs: Int) -> NSAttributedString {
        let body = (1...paragraphs)
            .map { "Paragraph \($0). The quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
        return NSAttributedString(
            string: body,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
    }

    private static func makeStack(paragraphs: Int) -> PageStackView {
        let stack = PageStackView()
        stack.setAttributedString(filler(paragraphs: paragraphs))
        return stack
    }

    /// The character range the layout manager assigned to `page`.
    private static func characterRange(ofPage page: Int, in stack: PageStackView) -> NSRange {
        let container = stack.pageViews[page].textContainer!
        let glyphs = stack.sharedLayoutManager.glyphRange(for: container)
        return stack.sharedLayoutManager.characterRange(
            forGlyphRange: glyphs, actualGlyphRange: nil
        )
    }

    // MARK: - Pagination

    @Test func emptyDocumentIsExactlyOnePage() {
        let stack = PageStackView()

        #expect(stack.pageCount == 1)
        #expect(stack.sharedLayoutManager.textContainers.count == 1)
    }

    @Test func longTextFlowsAcrossMultiplePages() {
        let stack = Self.makeStack(paragraphs: 200)

        #expect(stack.pageCount > 1)
        // One text view per container, always.
        #expect(stack.pageViews.count == stack.sharedLayoutManager.textContainers.count)
    }

    @Test func pagesPartitionTheGlyphsWithNoGapsOrOverlap() {
        let stack = Self.makeStack(paragraphs: 200)
        let manager = stack.sharedLayoutManager

        var expectedNext = 0
        for view in stack.pageViews {
            let range = manager.glyphRange(for: view.textContainer!)
            #expect(range.location == expectedNext)
            expectedNext = NSMaxRange(range)
        }
        // Every glyph landed on exactly one page.
        #expect(expectedNext == manager.numberOfGlyphs)
    }

    @Test func pageCountShrinksWhenTextIsDeleted() {
        let stack = Self.makeStack(paragraphs: 200)
        let grown = stack.pageCount
        #expect(grown > 1)

        stack.setAttributedString(Self.filler(paragraphs: 2))

        #expect(stack.pageCount == 1)
        #expect(stack.sharedLayoutManager.textContainers.count == 1)
    }

    @Test func documentHeightMatchesThePageCount() {
        let stack = Self.makeStack(paragraphs: 200)
        let layout = PagedEditorLayout.letter

        #expect(
            abs(stack.frame.height - layout.documentHeight(forPageCount: stack.pageCount)) < 0.5
        )
    }

    // MARK: - Selection: the actual gate

    @Test func allPageViewsShareOneSelection() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        let target = NSRange(location: 5, length: 10)
        stack.pageViews[0].setSelectedRange(target)

        // A shared layout manager is supposed to mean a shared selection: the
        // page-1 view must report the same range, not its own independent one.
        for view in stack.pageViews {
            #expect(view.selectedRange() == target)
        }
    }

    @Test func layoutManagerReportsThePageViewHoldingTheSelection() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        let secondPage = Self.characterRange(ofPage: 1, in: stack)
        stack.pageViews[0].setSelectedRange(NSRange(location: secondPage.location + 5, length: 0))

        #expect(stack.focusedPageView === stack.pageViews[1])
    }

    @Test func aCharacterIndexResolvesToThePageDisplayingIt() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        for page in 0..<stack.pageCount {
            let range = Self.characterRange(ofPage: page, in: stack)
            guard range.length > 0 else { continue }
            #expect(stack.pageView(forCharacterIndex: range.location) === stack.pageViews[page])
        }
    }

    @Test func selectionCanSpanAPageBoundary() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        let firstPage = Self.characterRange(ofPage: 0, in: stack)
        let boundary = NSMaxRange(firstPage)
        // Straddle the break: last 20 chars of page 0 through first 20 of page 1.
        let spanning = NSRange(location: boundary - 20, length: 40)
        stack.pageViews[0].setSelectedRange(spanning)

        #expect(stack.pageViews[0].selectedRange() == spanning)
        // The selection's glyphs must be reported on both pages' containers.
        let manager = stack.sharedLayoutManager
        let glyphs = manager.glyphRange(forCharacterRange: spanning, actualCharacterRange: nil)
        let page0 = manager.glyphRange(for: stack.pageViews[0].textContainer!)
        let page1 = manager.glyphRange(for: stack.pageViews[1].textContainer!)
        #expect(NSIntersectionRange(glyphs, page0).length > 0)
        #expect(NSIntersectionRange(glyphs, page1).length > 0)
    }

    @Test func caretMovingDownOffTheLastLineOfAPageLandsOnTheNextPage() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        let firstPage = Self.characterRange(ofPage: 0, in: stack)
        // Put the caret on the final line of page 0.
        let caret = NSMaxRange(firstPage) - 2
        let view = stack.pageViews[0]
        view.setSelectedRange(NSRange(location: caret, length: 0))

        view.moveDown(nil)

        let moved = view.selectedRange().location
        #expect(moved >= NSMaxRange(firstPage))
        #expect(stack.focusedPageView === stack.pageViews[1])
    }

    @Test func typingOnALaterPageInsertsAtThatPointInTheSharedStorage() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        let secondPage = Self.characterRange(ofPage: 1, in: stack)
        let insertAt = secondPage.location + 3
        let view = stack.pageViews[1]
        view.setSelectedRange(NSRange(location: insertAt, length: 0))

        view.insertText("ZZZ", replacementRange: NSRange(location: insertAt, length: 0))

        let inserted = (stack.storage.string as NSString)
            .substring(with: NSRange(location: insertAt, length: 3))
        #expect(inserted == "ZZZ")
    }

    // MARK: - First-responder handoff (plan §6 item 2)
    //
    // The tests above drive the views directly; these put the stack in a real
    // window so focus actually moves between page views, which is how a user
    // clicking from page 1 to page 2 exercises it.

    /// Hosts `stack` in an off-screen window so `makeFirstResponder` behaves.
    private static func inWindow(_ stack: PageStackView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.documentView = stack
        window.contentView = scrollView
        return window
    }

    @Test func focusMovesBetweenPageViewsAndKeepsOneSharedSelection() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)
        let window = Self.inWindow(stack)

        #expect(window.makeFirstResponder(stack.pageViews[0]))
        #expect(window.firstResponder === stack.pageViews[0])

        // Focus page 1, as a click on the second sheet of paper would.
        #expect(window.makeFirstResponder(stack.pageViews[1]))
        #expect(window.firstResponder === stack.pageViews[1])

        // Handing focus over must not fork the selection into two independent
        // insertion points — the whole stack is still one document.
        let secondPage = Self.characterRange(ofPage: 1, in: stack)
        let caret = NSRange(location: secondPage.location + 4, length: 0)
        stack.pageViews[1].setSelectedRange(caret)
        #expect(stack.pageViews[0].selectedRange() == caret)
    }

    @Test func typingGoesToTheFocusedPageAfterAFocusChange() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)
        let window = Self.inWindow(stack)

        #expect(window.makeFirstResponder(stack.pageViews[1]))
        let secondPage = Self.characterRange(ofPage: 1, in: stack)
        let insertAt = secondPage.location + 6
        stack.pageViews[1].setSelectedRange(NSRange(location: insertAt, length: 0))

        guard let responder = window.firstResponder as? PageTextView else {
            Issue.record("focused view was not a PageTextView")
            return
        }
        responder.insertText("QQ", replacementRange: responder.selectedRange())

        let written = (stack.storage.string as NSString)
            .substring(with: NSRange(location: insertAt, length: 2))
        #expect(written == "QQ")
    }

    // MARK: - Milestone 1: canvas, chrome, and edit-driven repagination

    /// Yields the main actor so `schedulePagination`'s deferred rebuild runs,
    /// the way it would between user keystrokes. Suspending (rather than
    /// blocking the run loop) is what actually lets the queued block execute.
    private static func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test func typingEnoughTextAddsAPageWithoutAnExplicitRebuild() async {
        let stack = Self.makeStack(paragraphs: 2)
        #expect(stack.pageCount == 1)

        stack.pageViews[0].insertText(
            String(repeating: "Filler sentence for pagination. ", count: 400),
            replacementRange: NSRange(location: 0, length: 0)
        )
        await Self.settle()

        #expect(stack.pageCount > 1)
    }

    @Test func deletingTextRemovesPagesWithoutAnExplicitRebuild() async {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        stack.storage.replaceCharacters(
            in: NSRange(location: 0, length: stack.storage.length),
            with: "Short."
        )
        await Self.settle()

        #expect(stack.pageCount == 1)
    }

    @Test func pageCountChangesAreReported() {
        let stack = PageStackView()
        var reported: [Int] = []
        stack.pageCountDidChange = { reported.append($0) }

        stack.setAttributedString(Self.filler(paragraphs: 200))

        #expect(reported.last == stack.pageCount)
        #expect(stack.pageCount > 1)
    }

    @Test func paperFramesStackVerticallyWithThePageGap() {
        let stack = Self.makeStack(paragraphs: 200)
        let layout = PagedEditorLayout.letter

        let first = stack.paperFrame(forPage: 0)
        let second = stack.paperFrame(forPage: 1)

        #expect(abs(second.minY - first.maxY - layout.pageGap) < 0.5)
        #expect(first.size == layout.paperSize)
    }

    @Test func paperIsInsetFromTheCanvasEdgeOnBothSides() {
        let stack = Self.makeStack(paragraphs: 2)
        let paper = stack.paperFrame(forPage: 0)

        #expect(abs(paper.minX - PageStackView.canvasPadding) < 0.5)
        #expect(abs(stack.canvasWidth - paper.maxX - PageStackView.canvasPadding) < 0.5)
    }

    @Test func scrollViewFactoryHostsAMagnifiablePageStack() throws {
        let scrollView = PageStackView.makeScrollView()

        let stack = try #require(scrollView.documentView as? PageStackView)
        #expect(scrollView.allowsMagnification)
        #expect(abs(scrollView.canvasWidth - stack.canvasWidth) < 0.5)
    }

    // MARK: - Cross-page drag selection (plan §6 item 1)

    /// Hosts the stack in a key window and runs a real drag through NSTextView's
    /// modal mouse-tracking loop, by pre-posting the drag and mouse-up events so
    /// the loop consumes them. Returns the resulting selection.
    private static func performDrag(
        in stack: PageStackView,
        fromStackPoint start: NSPoint,
        toStackPoint end: NSPoint
    ) -> NSRange {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        scrollView.documentView = stack
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)

        let startView = stack.pageViews.first { $0.frame.contains(start) } ?? stack.pageViews[0]
        _ = window.makeFirstResponder(startView)

        func mouse(_ type: NSEvent.EventType, _ stackPoint: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: stack.convert(stackPoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )!
        }

        window.postEvent(mouse(.leftMouseDragged, end), atStart: false)
        window.postEvent(mouse(.leftMouseUp, end), atStart: false)
        startView.mouseDown(with: mouse(.leftMouseDown, start))

        return startView.selectedRange()
    }

    /// The interaction the whole per-page model hinges on: sweeping the mouse
    /// from one sheet of paper onto the next must select straight through the
    /// page break, not stop at the bottom of the first page.
    ///
    /// This works without any custom tracking code. Note that
    /// `characterIndexForInsertion(at:)` on a single page view *does* clamp to
    /// its own container — but NSTextView's drag tracking does not go through
    /// that method, so the clamping is not what governs drag selection.
    @Test func draggingOntoTheNextPageSelectsThroughThePageBreak() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)
        let firstPage = Self.characterRange(ofPage: 0, in: stack)

        let selection = Self.performDrag(
            in: stack,
            fromStackPoint: NSPoint(x: 200, y: stack.paperFrame(forPage: 0).midY),
            toStackPoint: NSPoint(x: 200, y: stack.paperFrame(forPage: 1).midY)
        )

        // Started mid-page-0...
        #expect(selection.location > firstPage.location)
        #expect(selection.location < NSMaxRange(firstPage))
        // ...and ran past the page break into page 1's text.
        #expect(NSMaxRange(selection) > NSMaxRange(firstPage))
    }

    @Test func draggingBackwardsFromALaterPageAlsoSpansThePageBreak() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)
        let firstPage = Self.characterRange(ofPage: 0, in: stack)

        // Drag upward: start on page 1, finish on page 0.
        let selection = Self.performDrag(
            in: stack,
            fromStackPoint: NSPoint(x: 200, y: stack.paperFrame(forPage: 1).midY),
            toStackPoint: NSPoint(x: 200, y: stack.paperFrame(forPage: 0).midY)
        )

        #expect(selection.location < NSMaxRange(firstPage))
        #expect(NSMaxRange(selection) > NSMaxRange(firstPage))
    }

    // MARK: - Milestone 2: floating images
    //
    // The reason the rearchitecture exists. In the single-container editor an
    // image anchored to a page's *first line* produced an exclusion rect whose
    // edges were expressed in two different coordinate spaces, which made
    // TextKit either drop the remaining text or stop wrapping it. Per-page
    // containers remove the translation entirely, so that case should be
    // unremarkable.

    /// Mirrors `PageStackView.imageGutter`.
    private static let imageGutter: CGFloat = 8

    /// A blank image of an exact size. Built from a bitmap representation rather
    /// than `lockFocus()` on purpose: lockFocus mutates the process-wide
    /// graphics context stack, and Swift Testing runs suites concurrently, so it
    /// intermittently broke unrelated font tests running at the same time. These
    /// tests only care about the image's geometry, never its pixels.
    private static func image(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width)),
            pixelsHigh: max(1, Int(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }

    /// Body text with an image attachment anchored at `location`, optionally
    /// pinned to an explicit page + paper origin.
    private static func stackWithImage(
        paragraphs: Int,
        at location: Int,
        size: NSSize = NSSize(width: 200, height: 150),
        position: FloatingImagePosition? = nil
    ) -> PageStackView {
        let text = NSMutableAttributedString(attributedString: filler(paragraphs: paragraphs))
        let attachment = NSTextAttachment()
        attachment.image = image(size)
        attachment.bounds = NSRect(origin: .zero, size: size)
        let piece = NSMutableAttributedString(attachment: attachment)
        if let position {
            piece.addAttribute(
                .inklingFloatingImagePosition,
                value: position,
                range: NSRange(location: 0, length: piece.length)
            )
        }
        text.insert(piece, at: min(location, text.length))

        let stack = PageStackView()
        stack.setAttributedString(text)
        stack.prepareFloatingImages()
        return stack
    }

    /// Total exclusion paths installed across every page.
    private static func exclusionCount(in stack: PageStackView) -> Int {
        stack.pageViews.reduce(0) { $0 + ($1.textContainer?.exclusionPaths.count ?? 0) }
    }

    @Test func aFloatingImageInstallsAnExclusionOnItsOwnPageOnly() {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)

        #expect(Self.exclusionCount(in: stack) == 1)
        let pagesWithExclusions = stack.pageViews.filter {
            !($0.textContainer?.exclusionPaths.isEmpty ?? true)
        }
        #expect(pagesWithExclusions.count == 1)
        // The image draws on the same page that excludes for it.
        let excludingPage = pagesWithExclusions.first
        #expect(excludingPage?.floatingImages.count == 1)
    }

    @Test func everyExclusionStaysInsideItsOwnPagesCoordinateSpace() {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)
        let layout = PagedEditorLayout.letter

        // An exclusion may poke one gutter outside the content box (the rect is
        // grown by the gutter so text keeps its gap); TextKit clips it to the
        // container. Anything beyond that would mean two coordinate spaces in
        // one rect — the bug being fixed, which produced rects tall enough to
        // bridge a page break.
        let slack = Self.imageGutter + 0.5

        for view in stack.pageViews {
            for path in view.textContainer?.exclusionPaths ?? [] {
                #expect(path.bounds.minY >= -slack)
                #expect(path.bounds.maxY <= layout.contentHeight + slack)
                #expect(path.bounds.height <= layout.contentHeight + 2 * slack)
                // The decisive one: never as tall as a whole page stride, which
                // is what a cross-page rect looked like.
                #expect(path.bounds.height < layout.pageStride)
            }
        }
    }

    /// The original reported failure: an image at the very top of a *later*
    /// page. Text must neither vanish nor ride under the image.
    @Test func anImagePinnedToTheTopOfALaterPageKeepsAllTextAndStillWraps() {
        let layout = PagedEditorLayout.letter
        // Pin to page 2's top-left content corner — the exact fragile case.
        let position = FloatingImagePosition(
            page: 2,
            origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
        )
        let stack = Self.stackWithImage(
            paragraphs: 200, at: 40, position: position
        )

        // 1. No text was lost: every glyph is still laid out on some page.
        let manager = stack.sharedLayoutManager
        var laidOut = 0
        for view in stack.pageViews {
            laidOut += manager.glyphRange(for: view.textContainer!).length
        }
        #expect(laidOut == manager.numberOfGlyphs)
        #expect(manager.numberOfGlyphs > 0)

        // 2. No degenerate collapsed final line (the vanishing signature).
        let lastLine = manager.lineFragmentRect(
            forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil
        )
        #expect(lastLine.height > 3)

        // 3. The exclusion really is on page 2, at that page's top.
        let page2 = stack.pageViews[2]
        let paths = page2.textContainer?.exclusionPaths ?? []
        #expect(paths.count == 1)
        #expect((paths.first?.bounds.minY ?? .infinity) < 10)
    }

    @Test func textOnThatPageWrapsBesideTheImageRatherThanUnderIt() {
        let layout = PagedEditorLayout.letter
        let imageWidth: CGFloat = 200
        let position = FloatingImagePosition(
            page: 2,
            origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
        )
        let stack = Self.stackWithImage(
            paragraphs: 200,
            at: 40,
            size: NSSize(width: imageWidth, height: 150),
            position: position
        )

        let manager = stack.sharedLayoutManager
        let container = stack.pageViews[2].textContainer!
        let glyphs = manager.glyphRange(for: container)
        #expect(glyphs.length > 0)

        // Lines level with the image must start to its right, not under it.
        var checkedAny = false
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
            guard usedRect.midY < 150 else { return }   // beside the image
            guard usedRect.width > 1 else { return }    // skip empty lines
            checkedAny = true
            #expect(usedRect.minX >= imageWidth - 0.5)
        }
        #expect(checkedAny)
    }

    @Test func anImageParkedBeyondTheTextKeepsItsPageAlive() {
        let layout = PagedEditorLayout.letter
        // Two paragraphs of text (one page), image pinned to page 3.
        let position = FloatingImagePosition(
            page: 3,
            origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
        )
        let stack = Self.stackWithImage(paragraphs: 2, at: 5, position: position)

        #expect(stack.pageCount >= 4)
        #expect(stack.pageViews[3].floatingImages.count == 1)
    }

    // MARK: - Image dragging, including across pages

    /// Drives a real image drag: press on the image, move to a point in stack
    /// coordinates, release. Returns the image's committed position.
    @discardableResult
    private static func dragImage(
        in stack: PageStackView,
        grabbingOnPage page: Int,
        to stackPoint: NSPoint
    ) -> FloatingImagePosition? {
        // Hosted directly in the window, with no clip view on purpose: the drag
        // path calls `autoscroll(with:)` before converting the event point (as
        // the shipping editor does), so inside a scroll view a synthetic drag to
        // an off-screen page scrolls the document and shifts the coordinates out
        // from under the very conversion being tested. Without a clip view
        // autoscroll is a no-op, which isolates page targeting.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack

        let pageView = stack.pageViews[page]
        guard let hit = pageView.floatingImages.first else { return nil }
        // Press in the middle of the image.
        let grabPoint = NSPoint(
            x: pageView.viewRect(forFloating: hit.rect).midX,
            y: pageView.viewRect(forFloating: hit.rect).midY
        )
        #expect(stack.beginImageDrag(at: grabPoint, in: pageView))

        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: stack.convert(stackPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(stack.continueImageDrag(with: event))
        #expect(stack.endImageDrag())

        return stack.floatingAttachment(at: hit.location)?.position
    }

    @Test func draggingAnImageOntoALaterPageMovesItToThatPage() throws {
        let layout = PagedEditorLayout.letter
        let stack = Self.stackWithImage(
            paragraphs: 200,
            at: 40,
            position: FloatingImagePosition(
                page: 0, origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
            )
        )
        #expect(stack.pageCount > 2)

        // Drop it in the middle of page 2's paper.
        let target = stack.paperFrame(forPage: 2)
        let position = try #require(Self.dragImage(
            in: stack,
            grabbingOnPage: 0,
            to: NSPoint(x: target.midX, y: target.midY)
        ))

        #expect(position.page == 2)
        // ...and the exclusion followed it: page 0 no longer excludes, page 2 does.
        #expect(stack.pageViews[0].textContainer?.exclusionPaths.isEmpty == true)
        #expect(stack.pageViews[2].textContainer?.exclusionPaths.count == 1)
        #expect(stack.pageViews[2].floatingImages.count == 1)
        #expect(stack.pageViews[0].floatingImages.isEmpty)
    }

    @Test func draggingAnImageBackToAnEarlierPageMovesItBack() throws {
        let layout = PagedEditorLayout.letter
        let stack = Self.stackWithImage(
            paragraphs: 200,
            at: 40,
            position: FloatingImagePosition(
                page: 2, origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
            )
        )

        let target = stack.paperFrame(forPage: 0)
        let position = try #require(Self.dragImage(
            in: stack,
            grabbingOnPage: 2,
            to: NSPoint(x: target.midX, y: target.midY)
        ))

        #expect(position.page == 0)
        #expect(stack.pageViews[0].floatingImages.count == 1)
    }

    @Test func aDraggedImageIsClampedInsideThePaper() throws {
        let layout = PagedEditorLayout.letter
        let size = NSSize(width: 200, height: 150)
        let stack = Self.stackWithImage(
            paragraphs: 200,
            at: 40,
            size: size,
            position: FloatingImagePosition(
                page: 0, origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
            )
        )

        // Aim well past the bottom-right corner of page 1's paper.
        let paper = stack.paperFrame(forPage: 1)
        let position = try #require(Self.dragImage(
            in: stack,
            grabbingOnPage: 0,
            to: NSPoint(x: paper.maxX + 500, y: paper.maxY - 5)
        ))

        #expect(position.origin.x <= layout.paperSize.width - size.width + 0.5)
        #expect(position.origin.y <= layout.paperSize.height - size.height + 0.5)
        #expect(position.origin.x >= -0.5)
        #expect(position.origin.y >= -0.5)
    }

    @Test func draggingAnImageNearTheColumnEdgeSnapsToIt() throws {
        let layout = PagedEditorLayout.letter
        let stack = Self.stackWithImage(
            paragraphs: 200,
            at: 40,
            position: FloatingImagePosition(
                page: 0, origin: CGPoint(x: 300, y: layout.topMargin)
            )
        )

        // Aim a few points off the left content edge — inside the snap threshold.
        let paper = stack.paperFrame(forPage: 0)
        let imageWidth: CGFloat = 200
        let position = try #require(Self.dragImage(
            in: stack,
            grabbingOnPage: 0,
            to: NSPoint(
                x: paper.minX + layout.leftMargin + 4 + imageWidth / 2,
                y: paper.minY + 300
            )
        ))

        #expect(abs(position.origin.x - layout.leftMargin) < 0.5)
    }

    @Test func aClickOnAnImageWithoutMovingDoesNotChangeItsPosition() {
        let layout = PagedEditorLayout.letter
        let start = FloatingImagePosition(
            page: 0, origin: CGPoint(x: layout.leftMargin, y: layout.topMargin)
        )
        let stack = Self.stackWithImage(paragraphs: 200, at: 40, position: start)

        let pageView = stack.pageViews[0]
        let hit = pageView.floatingImages.first!
        let rect = pageView.viewRect(forFloating: hit.rect)
        #expect(stack.beginImageDrag(at: NSPoint(x: rect.midX, y: rect.midY), in: pageView))
        #expect(stack.endImageDrag())

        #expect(stack.floatingAttachment(at: hit.location)?.position == start)
    }

    @Test func pressingOffAnyImageDoesNotStartADrag() {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)
        let pageView = stack.pageViews[0]

        // Bottom-right of the page, well away from a left-anchored image.
        let corner = NSPoint(
            x: pageView.bounds.maxX - 20,
            y: pageView.bounds.maxY - 20
        )
        #expect(stack.beginImageDrag(at: corner, in: pageView) == false)
        #expect(stack.moveSession == nil)
    }

    // MARK: - Image resizing

    /// Selects the image on `page` and returns its page view plus image rect.
    private static func selectImage(
        in stack: PageStackView, onPage page: Int
    ) -> (view: PageTextView, rect: NSRect, location: Int)? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack

        let pageView = stack.pageViews[page]
        guard let hit = pageView.floatingImages.first else { return nil }
        let rect = pageView.viewRect(forFloating: hit.rect)
        _ = stack.beginImageDrag(at: NSPoint(x: rect.midX, y: rect.midY), in: pageView)
        _ = stack.endImageDrag()
        return (pageView, rect, hit.location)
    }

    private static func dragEvent(_ point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    @Test func pressingAnImageSelectsItSoHandlesAppear() throws {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)
        let selected = try #require(Self.selectImage(in: stack, onPage: 0))

        #expect(stack.selectedImageLocation == selected.location)
        #expect(stack.selectedImageRect(in: selected.view) != nil)
        #expect(stack.handleRects(for: selected.rect).count == 4)
    }

    @Test func handlesSitOnTheImageCorners() throws {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)
        let selected = try #require(Self.selectImage(in: stack, onPage: 0))

        let handles = Dictionary(uniqueKeysWithValues: stack.handleRects(for: selected.rect))
        #expect(abs(handles[.topLeft]!.midX - selected.rect.minX) < 0.5)
        #expect(abs(handles[.topLeft]!.midY - selected.rect.minY) < 0.5)
        #expect(abs(handles[.bottomRight]!.midX - selected.rect.maxX) < 0.5)
        #expect(abs(handles[.bottomRight]!.midY - selected.rect.maxY) < 0.5)
    }

    @Test func draggingTheBottomRightHandleOutwardGrowsTheImage() throws {
        let size = NSSize(width: 200, height: 150)
        let stack = Self.stackWithImage(paragraphs: 200, at: 40, size: size)
        let selected = try #require(Self.selectImage(in: stack, onPage: 0))

        let corner = NSPoint(x: selected.rect.maxX, y: selected.rect.maxY)
        #expect(stack.beginImageResize(at: corner, in: selected.view))
        #expect(stack.continueImageResize(
            with: Self.dragEvent(NSPoint(x: corner.x + 60, y: corner.y + 45), in: selected.view),
            in: selected.view
        ))
        #expect(stack.endImageResize())

        let resized = try #require(stack.floatingAttachment(at: selected.location))
        #expect(resized.displaySize.width > size.width)
        // Aspect ratio is preserved.
        let ratio = resized.displaySize.width / resized.displaySize.height
        #expect(abs(ratio - size.width / size.height) < 0.05)
    }

    @Test func draggingTheTopLeftHandleInwardShrinksTheImage() throws {
        let size = NSSize(width: 200, height: 150)
        let stack = Self.stackWithImage(paragraphs: 200, at: 40, size: size)
        let selected = try #require(Self.selectImage(in: stack, onPage: 0))

        let corner = NSPoint(x: selected.rect.minX, y: selected.rect.minY)
        #expect(stack.beginImageResize(at: corner, in: selected.view))
        #expect(stack.continueImageResize(
            with: Self.dragEvent(NSPoint(x: corner.x + 50, y: corner.y + 38), in: selected.view),
            in: selected.view
        ))
        #expect(stack.endImageResize())

        let resized = try #require(stack.floatingAttachment(at: selected.location))
        #expect(resized.displaySize.width < size.width)
    }

    @Test func resizingNeverExceedsTheColumnOrCollapsesTheImage() throws {
        let layout = PagedEditorLayout.letter
        let stack = Self.stackWithImage(
            paragraphs: 200, at: 40, size: NSSize(width: 200, height: 150)
        )
        let selected = try #require(Self.selectImage(in: stack, onPage: 0))
        let corner = NSPoint(x: selected.rect.maxX, y: selected.rect.maxY)

        // Way too big.
        #expect(stack.beginImageResize(at: corner, in: selected.view))
        _ = stack.continueImageResize(
            with: Self.dragEvent(NSPoint(x: corner.x + 5_000, y: corner.y + 5_000), in: selected.view),
            in: selected.view
        )
        _ = stack.endImageResize()
        var size = try #require(stack.floatingAttachment(at: selected.location)).displaySize
        #expect(size.width <= layout.contentWidth + 0.5)

        // Way too small.
        let now = try #require(stack.selectedImageRect(in: selected.view))
        let corner2 = NSPoint(x: now.maxX, y: now.maxY)
        #expect(stack.beginImageResize(at: corner2, in: selected.view))
        _ = stack.continueImageResize(
            with: Self.dragEvent(NSPoint(x: corner2.x - 5_000, y: corner2.y - 5_000), in: selected.view),
            in: selected.view
        )
        _ = stack.endImageResize()
        size = try #require(stack.floatingAttachment(at: selected.location)).displaySize
        #expect(size.width >= 32 - 0.5)
    }

    @Test func resizingUpdatesTheExclusionSoTextRewraps() throws {
        let stack = Self.stackWithImage(
            paragraphs: 200, at: 40, size: NSSize(width: 120, height: 90)
        )
        let selected = try #require(Self.selectImage(in: stack, onPage: 0))
        let before = try #require(
            selected.view.textContainer?.exclusionPaths.first?.bounds.width
        )

        let corner = NSPoint(x: selected.rect.maxX, y: selected.rect.maxY)
        #expect(stack.beginImageResize(at: corner, in: selected.view))
        _ = stack.continueImageResize(
            with: Self.dragEvent(NSPoint(x: corner.x + 120, y: corner.y + 90), in: selected.view),
            in: selected.view
        )
        _ = stack.endImageResize()

        let after = try #require(
            selected.view.textContainer?.exclusionPaths.first?.bounds.width
        )
        #expect(after > before)
    }

    @Test func pressingAwayFromAnImageClearsTheSelection() throws {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)
        _ = try #require(Self.selectImage(in: stack, onPage: 0))
        #expect(stack.selectedImageLocation != nil)

        stack.clearImageSelection()

        #expect(stack.selectedImageLocation == nil)
        #expect(stack.selectedImageRect(in: stack.pageViews[0]) == nil)
    }

    @Test func pressingAHandleWithNothingSelectedDoesNotResize() {
        let stack = Self.stackWithImage(paragraphs: 200, at: 40)
        let pageView = stack.pageViews[0]
        let rect = pageView.viewRect(forFloating: pageView.floatingImages[0].rect)

        // No selection yet, so the corner is not a handle.
        #expect(stack.beginImageResize(at: NSPoint(x: rect.maxX, y: rect.maxY), in: pageView) == false)
        #expect(stack.resizeSession == nil)
    }

    // MARK: - Milestone 3: sidebars

    /// `alignedRight: false` places the box against the left content edge, which
    /// leaves room to widen it — a right-aligned box is already at its maximum
    /// width, since the box may not extend past the column.
    private static func stackWithSidebar(
        paragraphs: Int,
        page: Int,
        at location: Int = 40,
        alignedRight: Bool = true
    ) -> PageStackView {
        let stack = PageStackView()
        stack.setAttributedString(filler(paragraphs: paragraphs))

        let layout = PagedEditorLayout.letter
        let x = alignedRight
            ? layout.leftMargin + layout.contentWidth - SidebarStyle.defaultWidth
            : layout.leftMargin
        let sidebar = SidebarAttachment(
            contentData: nil,
            width: SidebarStyle.defaultWidth,
            position: FloatingImagePosition(
                page: page,
                origin: CGPoint(x: x, y: layout.topMargin)
            ),
            contentHeight: SidebarStyle.minContentHeight
        )
        stack.storage.insert(
            NSAttributedString(attachment: sidebar),
            at: min(location, stack.storage.length)
        )
        stack.prepareSidebars()

        // Host in a window so the child editors have somewhere to live.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = stack
        stack.rebuildFloatingImageLayout()
        return stack
    }

    @Test func aSidebarIsHostedByThePageItSitsOn() throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 2)

        let id = try #require(stack.sidebarAttachments.keys.first)
        let view = try #require(stack.sidebarViews[id])
        // The child editor is a subview of page 2, not of the stack, so it
        // scrolls and clips with its page.
        #expect(view.superview === stack.pageViews[2])
        #expect(stack.sidebarPlacements[id]?.page == 2)
    }

    @Test func aSidebarExcludesOnItsOwnPageOnly() throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 2)
        let layout = PagedEditorLayout.letter

        #expect(stack.pageViews[2].textContainer?.exclusionPaths.count == 1)
        for (index, view) in stack.pageViews.enumerated() where index != 2 {
            #expect(view.textContainer?.exclusionPaths.isEmpty == true)
        }
        // And the exclusion is page-local, like an image's.
        let path = try #require(stack.pageViews[2].textContainer?.exclusionPaths.first)
        #expect(path.bounds.height < layout.pageStride)
    }

    @Test func textWrapsToTheLeftOfARightHandSidebar() throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 2)
        let manager = stack.sharedLayoutManager
        let container = try #require(stack.pageViews[2].textContainer)
        let id = try #require(stack.sidebarAttachments.keys.first)
        // Use the box's real rect — it's only as tall as its content, so a
        // fixed Y cutoff would sample lines below it that are free to run full
        // width.
        let box = try #require(stack.sidebarPlacements[id]).rect

        var checked = false
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) {
            _, usedRect, _, _, _ in
            guard usedRect.midY > box.minY, usedRect.midY < box.maxY else { return }
            guard usedRect.width > 1 else { return }
            checked = true
            #expect(usedRect.maxX <= box.minX + 0.5)
        }
        #expect(checked)
    }

    @Test func draggingASidebarOntoAnotherPageRehomesItsChildView() throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1)
        let id = try #require(stack.sidebarAttachments.keys.first)
        let located = try #require(stack.sidebarViewRect(id))

        // Press inside the box, then drag to page 3.
        let press = NSPoint(x: located.rect.midX, y: located.rect.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: located.view.convert(press, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: stack.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(stack.handleSidebarMouseDown(at: press, in: located.view, event: event))

        let target = stack.paperFrame(forPage: 3)
        #expect(stack.continueSidebarDrag(
            with: Self.dragEvent(NSPoint(x: target.midX, y: target.midY), in: stack)
        ))
        #expect(stack.endSidebarDrag())

        #expect(stack.sidebarAttachments[id]?.position?.page == 3)
        #expect(stack.sidebarPlacements[id]?.page == 3)
        #expect(stack.sidebarViews[id]?.superview === stack.pageViews[3])
        #expect(stack.pageViews[1].textContainer?.exclusionPaths.isEmpty == true)
        #expect(stack.pageViews[3].textContainer?.exclusionPaths.count == 1)
    }

    @Test func resizingASidebarWidensItsExclusion() throws {
        // Left-aligned, so there is column room to grow into.
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1, alignedRight: false)
        let id = try #require(stack.sidebarAttachments.keys.first)
        let located = try #require(stack.sidebarViewRect(id))
        let startWidth = try #require(stack.sidebarAttachments[id]).width
        let startExclusion = try #require(
            stack.pageViews[1].textContainer?.exclusionPaths.first?.bounds.width
        )

        // Select it, then grab the bottom-right handle and drag outward.
        stack.selectedSidebar = id
        let handle = stack.sidebarResizeHandleRect(located.rect)
        let press = NSPoint(x: handle.midX, y: handle.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: located.view.convert(press, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: stack.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(stack.handleSidebarMouseDown(at: press, in: located.view, event: event))
        #expect(stack.continueSidebarDrag(
            with: Self.dragEvent(NSPoint(x: press.x + 60, y: press.y), in: located.view)
        ))
        #expect(stack.endSidebarDrag())

        #expect(try #require(stack.sidebarAttachments[id]).width > startWidth)
        let endExclusion = try #require(
            stack.pageViews[1].textContainer?.exclusionPaths.first?.bounds.width
        )
        #expect(endExclusion > startExclusion)
    }

    @Test func aRightAlignedSidebarCannotBeWidenedPastTheColumn() throws {
        let layout = PagedEditorLayout.letter
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1)
        let id = try #require(stack.sidebarAttachments.keys.first)
        let located = try #require(stack.sidebarViewRect(id))
        stack.selectedSidebar = id

        let handle = stack.sidebarResizeHandleRect(located.rect)
        let press = NSPoint(x: handle.midX, y: handle.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: located.view.convert(press, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: stack.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        #expect(stack.handleSidebarMouseDown(at: press, in: located.view, event: event))
        _ = stack.continueSidebarDrag(
            with: Self.dragEvent(NSPoint(x: press.x + 400, y: press.y), in: located.view)
        )
        _ = stack.endSidebarDrag()

        // Its left edge is fixed, so it can never extend past the right margin.
        let sidebar = try #require(stack.sidebarAttachments[id])
        let leftInColumn = (sidebar.position?.origin.x ?? 0) - layout.leftMargin
        #expect(leftInColumn + sidebar.width <= layout.contentWidth + 0.5)
    }

    @Test func removingASidebarsAnchorDropsItsChildView() throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1)
        let id = try #require(stack.sidebarAttachments.keys.first)
        #expect(stack.sidebarViews[id] != nil)

        // Delete the whole text, anchor included.
        stack.storage.replaceCharacters(
            in: NSRange(location: 0, length: stack.storage.length), with: "Nothing left."
        )
        stack.rebuildFloatingImageLayout()

        #expect(stack.sidebarViews[id] == nil)
        #expect(stack.sidebarAttachments.isEmpty)
        #expect(stack.pageViews.allSatisfy { $0.textContainer?.exclusionPaths.isEmpty == true })
    }

    // MARK: - Milestone 3: callouts
    //
    // Callout chrome is drawn by the shared CalloutLayoutManager, which the
    // stack builds with `pageLayout` nil — the printer's configuration, where
    // each container is already exactly one page. So a callout should be bounded
    // to its page for free, with no page-grouping logic.

    @Test func theStackUsesThePrinterCalloutConfiguration() {
        let stack = PageStackView()
        // nil means "each container is one page", so drawBackground restricts
        // each box to the container being drawn instead of grouping by Y.
        #expect(stack.sharedLayoutManager.pageLayout == nil)
    }

    @Test func aCalloutSpanningAPageBreakStaysLaidOutOnBothPages() throws {
        let stack = PageStackView()
        let text = NSMutableAttributedString(attributedString: Self.filler(paragraphs: 200))
        stack.setAttributedString(text)

        // Find a paragraph range straddling the first page break and mark it.
        let firstPage = Self.characterRange(ofPage: 0, in: stack)
        let boundary = NSMaxRange(firstPage)
        let calloutRange = NSRange(location: max(0, boundary - 150), length: 300)
        stack.storage.addAttribute(
            .inklingCallout, value: CalloutKind.note.rawValue, range: calloutRange
        )
        stack.rebuildPages()

        // The callout's glyphs must still be distributed across both pages —
        // marking a callout must not disturb pagination or drop text.
        let manager = stack.sharedLayoutManager
        let glyphs = manager.glyphRange(forCharacterRange: calloutRange, actualCharacterRange: nil)
        let page0 = manager.glyphRange(for: try #require(stack.pageViews[0].textContainer))
        let page1 = manager.glyphRange(for: try #require(stack.pageViews[1].textContainer))
        #expect(NSIntersectionRange(glyphs, page0).length > 0)
        #expect(NSIntersectionRange(glyphs, page1).length > 0)

        var laidOut = 0
        for view in stack.pageViews {
            laidOut += manager.glyphRange(for: view.textContainer!).length
        }
        #expect(laidOut == manager.numberOfGlyphs)
    }

    // MARK: - Milestone 4: parity polish

    /// Hosts the stack in a scrolling canvas, as the real editor does.
    ///
    /// `width` matters: PagedEditorScrollView fits the paper to the viewport, so
    /// a viewport wider than the canvas runs at magnification 1 while a narrower
    /// one — the normal case in the app, where the editor pane is narrower than
    /// a page — runs magnified. Scrolling maths differs between the two.
    private static func inCanvas(
        _ stack: PageStackView, width: CGFloat = 800
    ) -> PagedEditorScrollView {
        let scrollView = PagedEditorScrollView(canvasWidth: stack.canvasWidth)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        scrollView.documentView = stack
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    /// Same, under the magnification the real editor runs at — magnification was
    /// the other candidate explanation for the find bug, and is also ruled out.
    @Test func findRevealsAMatchOnALaterPageEvenWhenMagnified() throws {
        let stack = Self.makeStack(paragraphs: 200)
        // Narrower than the canvas, so the page is scaled down to fit — what
        // happens whenever the editor pane is narrower than a sheet of paper.
        let scrollView = Self.inCanvas(stack, width: 400)
        #expect(scrollView.magnification < 1)
        #expect(stack.pageCount > 3)

        let target = Self.characterRange(ofPage: 3, in: stack)
        let match = NSRange(location: target.location + 20, length: 6)
        stack.pageViews[0].scrollRangeToVisible(match)

        let rect = try #require(stack.rect(forCharacterRange: match))
        let visible = scrollView.contentView.bounds
        #expect(rect.midY >= visible.minY, "match above viewport")
        #expect(rect.midY <= visible.maxY, "match below viewport")
    }

    @Test func allPageViewsShareOneUndoStack() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)

        // Each NSTextView would otherwise resolve its own through the responder
        // chain, so an edit on page 3 could land on a different stack than one
        // on page 1 — and the image/sidebar gestures on a third.
        for view in stack.pageViews {
            #expect(view.undoManager === stack.sharedUndoManager)
        }
    }

    @Test func everyPageGetsTheEditorConfigurationIncludingNewOnes() {
        let stack = PageStackView()
        stack.configurePage = { $0.isContinuousSpellCheckingEnabled = true }
        stack.setAttributedString(Self.filler(paragraphs: 2))
        #expect(stack.pageCount == 1)

        // Grow to several pages; the pages created by repagination must be
        // configured too, not just the ones present when the closure was set.
        stack.setAttributedString(Self.filler(paragraphs: 200))
        #expect(stack.pageCount > 1)
        let allConfigured = stack.pageViews.allSatisfy { $0.isContinuousSpellCheckingEnabled }
        #expect(allConfigured)
    }

    @Test func scrollingToARangeOnALaterPageSelectsItThere() throws {
        let stack = Self.makeStack(paragraphs: 200)
        _ = Self.inCanvas(stack)
        #expect(stack.pageCount > 2)

        let thirdPage = Self.characterRange(ofPage: 2, in: stack)
        let target = NSRange(location: thirdPage.location + 10, length: 5)
        stack.scroll(toCharacterRange: target)

        #expect(stack.pageViews[0].selectedRange() == target)
        #expect(stack.focusedPageView === stack.pageViews[2])
    }

    @Test func scrollingToARangeBringsItIntoTheViewport() throws {
        let stack = Self.makeStack(paragraphs: 200)
        let scrollView = Self.inCanvas(stack)
        #expect(stack.pageCount > 2)

        let thirdPage = Self.characterRange(ofPage: 2, in: stack)
        stack.scroll(toCharacterRange: NSRange(location: thirdPage.location + 10, length: 5))

        let caret = try #require(stack.caretRectInStack())
        let visible = scrollView.contentView.bounds
        #expect(caret.midY >= visible.minY - 0.5)
        #expect(caret.midY <= visible.maxY + 0.5)
    }

    @Test func typewriterScrollingPinsTheCaretAtTheAnchorFraction() throws {
        let stack = Self.makeStack(paragraphs: 200)
        let scrollView = Self.inCanvas(stack)
        stack.isTypewriterScrollingEnabled = true

        // Put the caret well down the document so there is room to scroll.
        let page = Self.characterRange(ofPage: 3, in: stack)
        stack.pageViews[0].setSelectedRange(NSRange(location: page.location + 20, length: 0))
        stack.scrollCaretToTypewriterPosition()

        let caret = try #require(stack.caretRectInStack())
        let visible = scrollView.contentView.bounds
        let fraction = (caret.midY - visible.minY) / visible.height
        #expect(abs(fraction - PageStackView.typewriterAnchorFraction) < 0.02)
    }

    @Test func typewriterScrollingDoesNothingWhenDisabled() throws {
        let stack = Self.makeStack(paragraphs: 200)
        let scrollView = Self.inCanvas(stack)
        stack.isTypewriterScrollingEnabled = false
        let before = scrollView.contentView.bounds.origin.y

        let page = Self.characterRange(ofPage: 3, in: stack)
        stack.pageViews[0].setSelectedRange(NSRange(location: page.location + 20, length: 0))
        stack.scrollCaretToTypewriterPosition()

        #expect(abs(scrollView.contentView.bounds.origin.y - before) < 0.5)
    }

    @Test func theCaretRectIsResolvedEvenForAnEmptyDocument() throws {
        let stack = PageStackView()
        _ = Self.inCanvas(stack)

        let caret = try #require(stack.caretRectInStack())
        // Inside page 1's text column, not at the very top of the paper.
        #expect(caret.minY >= PagedEditorLayout.letter.topMargin - 0.5)
    }

    /// Plan §4: the printer already lays one container per page, and the editor
    /// now does the same, so their page counts should agree — this is the
    /// property that used to require two independent implementations to match.
    @Test func pageStackAndPrinterAgreeOnPageCount() throws {
        // Letter minus 1" margins — what ManuscriptPrinter hands the print view,
        // and the content band the page stack lays into.
        let printPageSize = NSSize(width: 612 - 144, height: 792 - 144)
        let body = NSAttributedString(
            string: String(
                repeating: "A comfortably long manuscript line that wraps across the printable page. ",
                count: 300
            ),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let data = try #require(
            body.rtf(from: NSRange(location: 0, length: body.length), documentAttributes: [:])
        )

        let stack = PageStackView()
        stack.setAttributedString(body)

        let printView = ManuscriptPrintView(
            chapters: [PrintableChapter(title: "Ch 0", bodyData: data)],
            pageSize: printPageSize
        )

        // The printer adds chrome the editor doesn't (a chapter title block), so
        // allow a page of slack — the same tolerance the existing editor/print
        // agreement test uses per chapter.
        #expect(
            abs(stack.pageCount - printView.pageCount) <= 1,
            "stack=\(stack.pageCount) print=\(printView.pageCount)"
        )
    }

    /// The find bar searches its client text view's `string`. Because every page
    /// view shares one storage, that string is the whole chapter rather than the
    /// page's slice — which is what lets a find started on page 1 match text on
    /// page 5 and select it there.
    @Test func eachPageViewSeesTheWholeDocumentNotJustItsOwnPage() throws {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 2)

        let whole = stack.storage.string
        for view in stack.pageViews {
            #expect(view.string == whole)
        }

        // A match found late in the document resolves onto its real page.
        let needle = "Paragraph 180."
        let found = (whole as NSString).range(of: needle)
        #expect(found.location != NSNotFound)
        let host = try #require(stack.pageView(forCharacterIndex: found.location))
        #expect(host !== stack.pageViews[0])
        stack.scroll(toCharacterRange: found)
        #expect(stack.focusedPageView === host)
    }

    // MARK: - Regressions

    /// `NSTextView.font` restyles the whole storage, and `configurePage` runs
    /// for every page appended by repagination — long after the chapter loads.
    /// Setting the body font there reset every Title/Heading run to body each
    /// time the document grew a page.
    @Test func headingStylesSurviveThePagesAddedByRepagination() throws {
        let heading = NSFont.boldSystemFont(ofSize: 24)
        let text = NSMutableAttributedString(
            string: "Chapter One\n", attributes: [.font: heading]
        )
        text.append(Self.filler(paragraphs: 200))

        let stack = PageStackView()
        // The real configuration the editor installs, not a stand-in — the bug
        // lived inside that closure, so a hand-rolled one would not catch it.
        stack.configurePage = PageStackView.standardPageConfiguration()
        stack.setAttributedString(text)
        #expect(stack.pageCount > 1)

        let font = try #require(
            stack.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        #expect(font.pointSize == 24)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func aMixOfStylesSurvivesRepeatedRepagination() throws {
        let title = NSFont.boldSystemFont(ofSize: 28)
        let body = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: "Title\n", attributes: [.font: title])
        text.append(NSAttributedString(string: "Body text.\n", attributes: [.font: body]))
        text.append(Self.filler(paragraphs: 50))

        let stack = PageStackView()
        stack.configurePage = PageStackView.standardPageConfiguration()
        stack.setAttributedString(text)

        // Grow and shrink repeatedly; styling must be untouched throughout.
        for count in [200, 20, 300] {
            let more = NSMutableAttributedString(attributedString: text)
            more.append(Self.filler(paragraphs: count))
            stack.setAttributedString(more)

            let titleFont = try #require(
                stack.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            )
            #expect(titleFont.pointSize == 28)
        }
    }

    /// Typing in a sidebar used to relayout the whole chapter twice per
    /// keystroke. Only a change to the box's height affects how body text wraps.
    @Test func typingInASidebarWithoutResizingItDoesNotRelayoutTheChapter() throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1)
        let id = try #require(stack.sidebarAttachments.keys.first)
        let view = try #require(stack.sidebarViews[id])
        let sidebar = try #require(stack.sidebarAttachments[id])

        // Match the attachment's recorded height to the view's, as a settled
        // layout would.
        sidebar.contentHeight = view.fittingTextHeight()
        let before = stack.floatingLayoutRebuildCount

        // A few characters that fit on the box's existing line.
        view.onEdited?()
        view.onEdited?()
        view.onEdited?()

        #expect(stack.floatingLayoutRebuildCount == before)
    }

    @Test func typingThatGrowsASidebarDoesRelayoutTheChapter() async throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1)
        let id = try #require(stack.sidebarAttachments.keys.first)
        let view = try #require(stack.sidebarViews[id])
        let sidebar = try #require(stack.sidebarAttachments[id])
        let before = stack.floatingLayoutRebuildCount

        // Pretend the box got taller than its recorded height.
        sidebar.contentHeight = view.fittingTextHeight() - 40
        view.onEdited?()
        await Self.settle()

        #expect(stack.floatingLayoutRebuildCount > before)
    }

    @Test func aBurstOfSidebarGrowthCoalescesIntoOneRelayout() async throws {
        let stack = Self.stackWithSidebar(paragraphs: 200, page: 1)
        let id = try #require(stack.sidebarAttachments.keys.first)
        let view = try #require(stack.sidebarViews[id])
        let sidebar = try #require(stack.sidebarAttachments[id])
        let before = stack.floatingLayoutRebuildCount

        // Five height-changing edits in one run-loop pass.
        for _ in 0..<5 {
            sidebar.contentHeight = view.fittingTextHeight() - 40
            view.onEdited?()
        }
        await Self.settle()

        #expect(stack.floatingLayoutRebuildCount - before == 1)
    }

    // MARK: - Word-import-shaped images
    //
    // WordDocumentImporter creates plain attachments with no saved position —
    // "no attempt is made to reproduce Word's on-page pixel position" — so
    // imported images take the anchor-relative float path rather than the
    // explicitly-placed one. That path is precisely what the old editor
    // expressed in pre-pagination coordinates and got wrong near a page top.

    /// Inserts un-placed attachments (what an import produces) at several
    /// mid-paragraph anchors spread through a long chapter.
    private static func stackWithImportedImages(
        size: NSSize = NSSize(width: 200, height: 150),
        anchors: [Int]
    ) -> PageStackView {
        let text = NSMutableAttributedString(attributedString: filler(paragraphs: 200))
        for location in anchors.sorted(by: >) {
            let attachment = NSTextAttachment()
            attachment.image = image(size)
            attachment.bounds = NSRect(origin: .zero, size: size)
            text.insert(
                NSAttributedString(attachment: attachment),
                at: min(location, text.length)
            )
        }
        let stack = PageStackView()
        stack.setAttributedString(text)
        stack.prepareFloatingImages()
        return stack
    }

    @Test func importedImagesLandPageLocallyWithNoTextLost() throws {
        let stack = Self.stackWithImportedImages(
            anchors: [500, 4_000, 9_000, 14_000]
        )
        let layout = PagedEditorLayout.letter
        let manager = stack.sharedLayoutManager

        // No text lost, no degenerate collapsed tail — the two original failures.
        var laidOut = 0
        for view in stack.pageViews {
            laidOut += manager.glyphRange(for: view.textContainer!).length
        }
        #expect(laidOut == manager.numberOfGlyphs)
        #expect(
            manager.lineFragmentRect(
                forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil
            ).height > 3
        )

        // Every exclusion is page-local, and each image draws on the page that
        // excludes for it.
        var totalExclusions = 0
        for view in stack.pageViews {
            let paths = view.textContainer?.exclusionPaths ?? []
            totalExclusions += paths.count
            for path in paths {
                #expect(path.bounds.height < layout.pageStride)
            }
            if !paths.isEmpty { #expect(!view.floatingImages.isEmpty) }
        }
        #expect(totalExclusions == 4)
    }

    /// The original reported failure, reached the way an import reaches it: an
    /// image anchored so late on its page that it cannot fit, and is therefore
    /// pushed to the top of the next page — a first-line image.
    @Test func anImportedImageBumpedToTheNextPageTopStillWrapsText() throws {
        let layout = PagedEditorLayout.letter
        let size = NSSize(width: 200, height: 150)

        // Lay out plain text first, then find a character whose line sits too
        // low on its page for the image to fit beneath it.
        let probe = PageStackView()
        probe.setAttributedString(Self.filler(paragraphs: 200))
        let manager = probe.sharedLayoutManager
        let container = try #require(probe.pageViews[1].textContainer)
        let pageGlyphs = manager.glyphRange(for: container)

        var anchorGlyph: Int?
        manager.enumerateLineFragments(forGlyphRange: pageGlyphs) { rect, _, _, range, stop in
            if rect.minY + size.height > layout.contentHeight {
                anchorGlyph = range.location
                stop.pointee = true
            }
        }
        let glyph = try #require(anchorGlyph)
        let anchor = manager.characterIndexForGlyph(at: glyph)

        let stack = Self.stackWithImportedImages(size: size, anchors: [anchor])

        // It moved to a later page and sits at that page's top.
        let hosting = try #require(
            stack.pageViews.first { !$0.floatingImages.isEmpty }
        )
        let placed = try #require(hosting.floatingImages.first)
        #expect(placed.rect.minY < 1)
        #expect(hosting.pageIndex >= 2)

        // Text beside it wraps to its right rather than running underneath —
        // the exact symptom that was reported.
        let hostContainer = try #require(hosting.textContainer)
        var checkedAny = false
        stack.sharedLayoutManager.enumerateLineFragments(
            forGlyphRange: stack.sharedLayoutManager.glyphRange(for: hostContainer)
        ) { _, usedRect, _, _, _ in
            guard usedRect.midY < placed.rect.maxY, usedRect.width > 1 else { return }
            checkedAny = true
            #expect(usedRect.minX >= size.width - 0.5)
        }
        #expect(checkedAny)

        // And nothing was lost getting there.
        var laidOut = 0
        for view in stack.pageViews {
            laidOut += stack.sharedLayoutManager.glyphRange(for: view.textContainer!).length
        }
        #expect(laidOut == stack.sharedLayoutManager.numberOfGlyphs)
    }

    /// Pins that NSTextView's own scrollRangeToVisible already resolves a range
    /// on any page through the shared layout manager. This does NOT reproduce
    /// the reported find bug — it is the evidence that ruled that theory out,
    /// kept so the same wrong fix isn't attempted again.
    @Test func scrollRangeToVisibleFromOnePageRevealsAMatchOnAnother() throws {
        let stack = Self.makeStack(paragraphs: 200)
        let scrollView = Self.inCanvas(stack)
        #expect(stack.pageCount > 3)

        let target = Self.characterRange(ofPage: 3, in: stack)
        let match = NSRange(location: target.location + 20, length: 6)

        // Exactly what the find bar does: ask page 0's view to reveal it.
        stack.pageViews[0].scrollRangeToVisible(match)

        let rect = try #require(stack.rect(forCharacterRange: match))
        let visible = scrollView.contentView.bounds
        #expect(rect.midY >= visible.minY)
        #expect(rect.midY <= visible.maxY)
    }

    @Test func aRangesRectResolvesOntoThePageThatHoldsIt() throws {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 2)

        for page in 0..<min(3, stack.pageCount) {
            let range = Self.characterRange(ofPage: page, in: stack)
            guard range.length > 20 else { continue }
            let rect = try #require(
                stack.rect(forCharacterRange: NSRange(location: range.location + 5, length: 4))
            )
            // The rect must fall inside that page's paper, not another's.
            let paper = stack.paperFrame(forPage: page)
            #expect(rect.midY >= paper.minY)
            #expect(rect.midY <= paper.maxY)
        }
    }

    @Test func revealingARangeLeavesTheSelectionAlone() throws {
        let stack = Self.makeStack(paragraphs: 200)
        _ = Self.inCanvas(stack)

        let chosen = NSRange(location: 12, length: 4)
        stack.pageViews[0].setSelectedRange(chosen)

        let later = Self.characterRange(ofPage: 2, in: stack)
        stack.revealCharacterRange(NSRange(location: later.location + 5, length: 3))

        // Find has already set its own selection; revealing must not move it.
        #expect(stack.pageViews[0].selectedRange() == chosen)
    }

    // MARK: - Which editor is the default

    @Test func thePerPageEditorIsOnWhenNothingHasBeenChosen() {
        let defaults = UserDefaults.standard
        let key = PageStackView.defaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        // An unset key must read as ON. `bool(forKey:)` would report false here,
        // silently keeping every existing install on the old editor.
        defaults.removeObject(forKey: key)
        #expect(PageStackView.isEnabled)
    }

    @Test func theOldEditorCanStillBeChosenExplicitly() {
        let defaults = UserDefaults.standard
        let key = PageStackView.defaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.set(false, forKey: key)
        #expect(PageStackView.isEnabled == false)
        defaults.set(true, forKey: key)
        #expect(PageStackView.isEnabled)
    }

    // MARK: - NSTextFinderClient across pages
    //
    // NSTextView answers the find client protocol as a single-view client: all
    // of its text is in itself. That is false here, and is the leading
    // explanation for a match being highlighted on the right page while the
    // scroll goes somewhere meaningless. These test the answers directly —
    // driving NSTextFinder end-to-end could not be made to run headless.

    @Test func theFindClientReportsThePageViewThatDisplaysAnIndex() throws {
        let stack = Self.makeStack(paragraphs: 200)
        _ = Self.inCanvas(stack)
        #expect(stack.pageCount > 2)

        for page in 0..<min(3, stack.pageCount) {
            let range = stack.characterRange(ofPage: page)
            guard range.length > 0 else { continue }
            var effective = NSRange(location: 0, length: 0)
            let view = stack.pageViews[0].contentView(
                at: range.location + 1, effectiveCharacterRange: &effective
            )
            // Asked from page 0's view, it must still name the page that shows
            // the character — that is the whole point of the protocol method.
            #expect(view === stack.pageViews[page])
            #expect(effective == range)
        }
    }

    @Test func theFindClientReturnsRectsInTheDisplayingPagesCoordinates() throws {
        let stack = Self.makeStack(paragraphs: 200)
        _ = Self.inCanvas(stack)
        #expect(stack.pageCount > 2)

        let page2 = stack.characterRange(ofPage: 2)
        let match = NSRange(location: page2.location + 10, length: 6)
        let rects = try #require(stack.pageViews[0].rects(forCharacterRange: match))
        #expect(!rects.isEmpty)

        // Page-local: within one page's bounds, not offset by two page strides.
        let host = stack.pageViews[2]
        for value in rects {
            #expect(host.bounds.contains(value.rectValue.origin))
        }
    }

    @Test func theFindClientReportsEveryVisiblePagesRange() throws {
        let stack = Self.makeStack(paragraphs: 200)
        let scrollView = Self.inCanvas(stack)
        #expect(stack.pageCount > 2)

        let visible = stack.pageViews[0].visibleCharacterRanges
        #expect(!visible.isEmpty)

        // Every reported range belongs to a page actually on screen.
        let onScreen = Set(stack.visiblePageViews().map(\.pageIndex))
        #expect(!onScreen.isEmpty)
        for value in visible {
            let page = try #require(stack.pageView(forCharacterIndex: value.rangeValue.location))
            #expect(onScreen.contains(page.pageIndex))
        }
        _ = scrollView
    }

    @Test func editingOnAnEarlyPageRepaginatesLaterPages() {
        let stack = Self.makeStack(paragraphs: 200)
        let before = Self.characterRange(ofPage: 1, in: stack)

        // Insert a large block on page 0; page 1's text must shift forward.
        stack.pageViews[0].insertText(
            String(repeating: "Filler sentence. ", count: 200),
            replacementRange: NSRange(location: 0, length: 0)
        )
        stack.rebuildPages()

        let after = Self.characterRange(ofPage: 1, in: stack)
        #expect(after.location != before.location)
    }
}
