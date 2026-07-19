//
//  PageStackView.swift
//  Inkling
//
//  MILESTONE 0 PROTOTYPE — the go/no-go gate for the per-page-container editor
//  rearchitecture (docs/per-page-container-editor-plan.md).
//
//  The shipping editor (`PagedTextView`) lays a whole chapter into ONE infinitely
//  tall text container and fakes page breaks with a layout delegate that nudges
//  each line's Y. That forces floating-image exclusion paths to be expressed in a
//  pre-pagination coordinate space, which is the root of the top-of-page image
//  bugs. The printer has none of those bugs because it uses one container per
//  page (`ManuscriptPrintView.layOutPages`).
//
//  This file mirrors the printer's structure for an *editable* surface: one
//  shared NSTextStorage + one shared layout manager feeding N containers, each
//  backed by its own small NSTextView. TextKit flows text container→container
//  natively, so pagination is real and every exclusion path is page-local.
//
//  Milestone 0 (the selection gate) is passed: N text views sharing one layout
//  manager keep a single insertion point, selection spans page breaks, the caret
//  crosses boundaries, and first-responder handoff doesn't fork the selection.
//
//  Milestone 1 (here) brings text-only parity with the shipping editor:
//  repagination driven by editing, the scrolling/magnifying canvas, and the
//  paper-and-shadow chrome. Still deliberately excluded: floating images,
//  sidebars, callout chrome, typewriter scrolling. Nothing here is wired into
//  the shipping editor.
//

import AppKit

extension PagedEditorLayout {
    /// Height of one page's text area — the container height in the per-page
    /// model. (The single-container editor never needed this: its one container
    /// is infinitely tall.)
    var contentHeight: CGFloat {
        paperSize.height - topMargin - bottomMargin
    }

    /// The paper rect for `page`, in page-stack coordinates (y grows downward).
    func paperRect(forPage page: Int) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(page) * pageStride,
            width: paperSize.width,
            height: paperSize.height
        )
    }
}

/// One page's editable text area. Fixed size: it never grows to fit text —
/// overflow is TextKit's cue to continue into the next page's container.
final class PageTextView: NSTextView {

    /// This view's index in the stack. Maintained by `PageStackView`.
    var pageIndex: Int = 0

    convenience init(pageIndex: Int, container: NSTextContainer, layout: PagedEditorLayout) {
        self.init(frame: layout.paperRect(forPage: pageIndex), textContainer: container)
        self.pageIndex = pageIndex

        // The view is a whole sheet of paper; the container is just the text
        // area, so the margins live in the inset. This is what makes container
        // coordinates page-local — an exclusion path for an image on this page
        // is expressed in 0…contentHeight, with no translation.
        textContainerInset = NSSize(width: layout.leftMargin, height: layout.topMargin)

        // Fixed-size, both axes. NSTextView's default is to grow to fit its
        // text; here the container's fixed height must be the binding
        // constraint, or text would never overflow to the next page.
        isHorizontallyResizable = false
        isVerticallyResizable = false
        autoresizingMask = []

        isEditable = true
        isSelectable = true
        isRichText = true
        allowsUndo = true

        // The stack draws the paper (with its shadow) beneath every page view,
        // so the views themselves are transparent — same split as the shipping
        // editor, which paints paper in `drawBackground(in:)`.
        drawsBackground = false
        // Pages are paper: keep them light regardless of system appearance,
        // matching the shipping editor.
        appearance = NSAppearance(named: .aqua)

        // Cmd-F drives the standard TextKit find bar, hosted by the enclosing
        // scroll view.
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }
}

/// The scrolling document view: a vertical stack of fixed-size page views, all
/// sharing one text storage and one layout manager.
final class PageStackView: NSView, NSTextStorageDelegate {

    /// Breathing room between the paper edge and the canvas edge, so a page
    /// doesn't sit flush against the scroll view. Matches `PagedTextView`.
    static let canvasPadding: CGFloat = 16

    let pageLayout: PagedEditorLayout
    let storage: NSTextStorage
    let sharedLayoutManager: CalloutLayoutManager

    private(set) var pageViews: [PageTextView] = []

    /// Reports a changed page count (for the editor footer), mirroring
    /// `PagedTextView.pageCountDidChange`.
    var pageCountDidChange: ((Int) -> Void)?

    /// Guards against `rebuildPages` re-entering itself by way of the layout it
    /// triggers.
    private var isRebuilding = false
    private var paginationScheduled = false

    override var isFlipped: Bool { true }

    /// Full canvas width: paper plus padding on both sides.
    var canvasWidth: CGFloat { pageLayout.paperSize.width + Self.canvasPadding * 2 }

    init(pageLayout: PagedEditorLayout = .letter) {
        self.pageLayout = pageLayout
        self.storage = NSTextStorage()
        self.sharedLayoutManager = CalloutLayoutManager()
        // nil: each container is already exactly one page, so callout boxes are
        // page-bounded for free — the same reason the printer leaves it nil.
        self.sharedLayoutManager.pageLayout = nil
        super.init(frame: NSRect(origin: .zero, size: pageLayout.paperSize))

        storage.addLayoutManager(sharedLayoutManager)
        storage.delegate = self
        appendPage()
        resizeToFitPages()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var pageCount: Int { pageViews.count }

    /// Replaces the whole document and repaginates.
    func setAttributedString(_ text: NSAttributedString) {
        storage.setAttributedString(text)
        rebuildPages()
    }

    // MARK: - Repagination driven by editing

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        schedulePagination()
    }

    /// Repaginates on the next pass of the run loop. Adding or removing text
    /// containers while the storage is still processing an edit re-enters
    /// TextKit; the shipping editor defers page updates the same way.
    private func schedulePagination() {
        guard !paginationScheduled else { return }
        paginationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.paginationScheduled = false
            self.rebuildPages()
        }
    }

    // MARK: - Pagination

    /// Grows or shrinks the page stack until it exactly holds the text, then
    /// resizes to match. Mirrors `ManuscriptPrintView.layOutPages`: add a
    /// container, ask the layout manager to fill it, repeat while glyphs remain.
    func rebuildPages() {
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        // Grow. `progressed` guards against a container that accepts no glyphs
        // at all (e.g. a line taller than the page), which would otherwise spin
        // forever adding pages.
        var guardCounter = 0
        while guardCounter < Self.maxPages {
            guardCounter += 1
            guard let last = pageViews.last?.textContainer else { break }
            sharedLayoutManager.ensureLayout(for: last)
            let laidOut = NSMaxRange(sharedLayoutManager.glyphRange(for: last))
            guard laidOut < sharedLayoutManager.numberOfGlyphs else { break }

            let before = pageViews.count
            appendPage()
            guard pageViews.count > before else { break }

            // If the newly added page accepted nothing, stop rather than loop.
            guard let added = pageViews.last?.textContainer else { break }
            sharedLayoutManager.ensureLayout(for: added)
            if sharedLayoutManager.glyphRange(for: added).length == 0 { break }
        }

        // Trim trailing pages that hold no glyphs, always keeping page 1.
        while pageViews.count > 1, let last = pageViews.last?.textContainer,
              sharedLayoutManager.glyphRange(for: last).length == 0 {
            removeLastPage()
        }

        let changed = pageViews.count != lastReportedPageCount
        resizeToFitPages()
        if changed {
            lastReportedPageCount = pageViews.count
            pageCountDidChange?(pageViews.count)
            needsDisplay = true
        }
    }

    private var lastReportedPageCount = 1

    /// Upper bound on pages, so a pathological layout can't hang the app.
    private static let maxPages = 5_000

    private func appendPage() {
        let index = pageViews.count
        let container = NSTextContainer(size: NSSize(
            width: pageLayout.contentWidth,
            height: pageLayout.contentHeight
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        sharedLayoutManager.addTextContainer(container)

        let view = PageTextView(pageIndex: index, container: container, layout: pageLayout)
        view.frame = paperFrame(forPage: index)
        addSubview(view)
        pageViews.append(view)
    }

    /// Where page `page`'s sheet of paper sits in stack coordinates — the pure
    /// page geometry nudged right by the canvas padding.
    func paperFrame(forPage page: Int) -> NSRect {
        pageLayout.paperRect(forPage: page).offsetBy(dx: Self.canvasPadding, dy: 0)
    }

    private func removeLastPage() {
        guard let view = pageViews.popLast() else { return }
        view.removeFromSuperview()
        let containerIndex = sharedLayoutManager.textContainers.count - 1
        if containerIndex >= 0 {
            sharedLayoutManager.removeTextContainer(at: containerIndex)
        }
    }

    private func resizeToFitPages() {
        let height = pageLayout.documentHeight(forPageCount: max(1, pageViews.count))
        // Never shrink below the viewport, or the last page can't scroll to a
        // comfortable position.
        let viewportHeight = enclosingScrollView?.contentSize.height ?? 0
        let size = NSSize(width: canvasWidth, height: max(height, viewportHeight))
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            setFrameSize(size)
        }
        for (index, view) in pageViews.enumerated() {
            view.pageIndex = index
            let rect = paperFrame(forPage: index)
            if view.frame != rect { view.frame = rect }
        }
    }

    // MARK: - Paper

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()

        for page in 0..<pageCount {
            let paper = paperFrame(forPage: page)
            guard paper.intersects(dirtyRect) else { continue }

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(rect: paper).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: paper).stroke()
        }
    }

    // MARK: - Canvas

    /// Builds the scrolling, magnifying canvas that hosts the page stack —
    /// the per-page-container counterpart to `PagedTextView.makePagedScrollView`.
    static func makeScrollView(pageLayout: PagedEditorLayout = .letter) -> PagedEditorScrollView {
        let stack = PageStackView(pageLayout: pageLayout)
        let scrollView = PagedEditorScrollView(canvasWidth: stack.canvasWidth)
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.contentInsets = NSEdgeInsets(top: 24, left: 0, bottom: 24, right: 0)
        return scrollView
    }

    // MARK: - Selection helpers

    /// The page view that currently holds the insertion point / start of the
    /// selection, according to the shared layout manager.
    var focusedPageView: PageTextView? {
        sharedLayoutManager.textViewForBeginningOfSelection as? PageTextView
    }

    /// The page view whose container holds `characterIndex`.
    func pageView(forCharacterIndex characterIndex: Int) -> PageTextView? {
        guard sharedLayoutManager.numberOfGlyphs > 0 else { return pageViews.first }
        let clamped = min(max(0, characterIndex), max(0, storage.length - 1))
        let glyph = sharedLayoutManager.glyphIndexForCharacter(at: clamped)
        guard let container = sharedLayoutManager.textContainer(
            forGlyphAt: glyph, effectiveRange: nil
        ) else { return nil }
        return pageViews.first { $0.textContainer === container }
    }
}
