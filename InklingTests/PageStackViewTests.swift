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
    //
    // A mouse drag that starts on page 0 and continues below it is tracked by
    // page 0's text view, which resolves the drag point against *its own*
    // container. This probes whether that resolution can reach text on page 1 —
    // i.e. whether cross-page drag selection works natively or needs handling
    // in PageStackView.

    @Test func draggingBelowAPageResolvesOnlyWithinThatPagesOwnText() {
        let stack = Self.makeStack(paragraphs: 200)
        #expect(stack.pageCount > 1)
        let firstPage = Self.characterRange(ofPage: 0, in: stack)

        // A point far below page 0's paper — where the user's cursor would be
        // after dragging down onto page 1.
        let farBelow = NSPoint(x: 200, y: stack.pageViews[0].bounds.maxY + 1_000)
        let index = stack.pageViews[0].characterIndexForInsertion(at: farBelow)

        // Page 0's view cannot see page 1's glyphs, so the drag clamps at the
        // end of its own container rather than reaching page 1. Cross-page drag
        // selection therefore needs explicit handling in the stack (routing the
        // drag point to whichever page view contains it); it does not come free
        // from TextKit the way the caret and shared selection do.
        #expect(index <= NSMaxRange(firstPage))
        // ...and it really is clamped to the page end, not some arbitrary spot:
        // the drag reaches the last line of page 0 and stops.
        #expect(index > firstPage.location)
        #expect(NSMaxRange(firstPage) - index < 100)
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
