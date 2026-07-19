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
        let excludingPage = try? #require(pagesWithExclusions.first)
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
