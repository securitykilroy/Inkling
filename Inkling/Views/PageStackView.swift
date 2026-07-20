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

/// Which corner of an image is being dragged to resize it. A near-copy of the
/// handle enum nested privately inside `PagedTextView`; the two converge when
/// the shipping editor is retired (plan §8 milestone 5).
enum PageResizeHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var dragsLeftEdge: Bool { self == .topLeft || self == .bottomLeft }
    var dragsTopEdge: Bool { self == .topLeft || self == .topRight }
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

    /// Floating images anchored to this page, in container-local coordinates
    /// (origin = the text column's top-left). `location` is the attachment's
    /// character index, so a hit test can map back to the attachment.
    var floatingImages: [(location: Int, rect: NSRect, image: NSImage)] = [] {
        didSet { needsDisplay = true }
    }

    /// This page view's rect for a floating image, in view coordinates. The view
    /// is the whole sheet of paper, so view coordinates *are* paper coordinates.
    func viewRect(forFloating rect: NSRect) -> NSRect {
        let origin = textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The floating image under `point` (view coordinates), topmost first.
    func floatingImage(at point: NSPoint) -> (location: Int, rect: NSRect, image: NSImage)? {
        floatingImages.reversed().first { viewRect(forFloating: $0.rect).contains(point) }
    }

    /// The stack hosting this page. Sidebars are child views of a page view, so
    /// this walks up rather than assuming a direct parent.
    var pageStack: PageStackView? { superview as? PageStackView }

    private var stack: PageStackView? { pageStack }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for item in floatingImages {
            item.image.draw(
                in: viewRect(forFloating: item.rect),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        stack?.drawImageSelection(in: self)
        stack?.drawSidebarSelection(in: self)
        stack?.drawSnapGuide(in: self)
    }

    // MARK: - Image dragging
    //
    // The drag session lives on the stack, not here, because a drag can carry an
    // image onto a different page — and therefore into a different view — partway
    // through. The stack owns the coordinate conversion.

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Sidebars first (they sit above the text and own their own hit area),
        // then image handles — handles sit on the image's corners and extend
        // past its edge, so an image-body hit test would swallow them.
        if stack?.handleSidebarMouseDown(at: point, in: self, event: event) == true { return }
        if stack?.beginImageResize(at: point, in: self) == true { return }
        if stack?.beginImageDrag(at: point, in: self) == true { return }
        stack?.clearImageSelection()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if stack?.continueSidebarDrag(with: event) == true { return }
        if stack?.continueImageResize(with: event, in: self) == true { return }
        if stack?.continueImageDrag(with: event) == true { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if stack?.endSidebarDrag() == true { return }
        if stack?.endImageResize() == true { return }
        if stack?.endImageDrag() == true { return }
        super.mouseUp(with: event)
    }

    /// All page views share the stack's undo manager, so undo is one stack for
    /// the whole document rather than one per page.
    override var undoManager: UndoManager? { pageStack?.sharedUndoManager }

    // NOTE: deliberately no `scrollRangeToVisible` override. It was tried as a
    // fix for the reported find-doesn't-jump bug on the theory that the find bar
    // asks the focused page view — not the page holding the match — to reveal
    // the range. That theory is wrong: NSTextView's own implementation resolves
    // a range on any page correctly through the shared layout manager, verified
    // both at magnification 1 and scaled down. The find bug is still unexplained;
    // the next suspect is NSTextFinderClient geometry (`rects(forCharacterRange:)`
    // and friends), which is per-view and so does not know about other pages.

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !stillSelectingFlag else { return }
        pageStack?.scrollCaretToTypewriterPosition()
    }
}

/// The scrolling document view: a vertical stack of fixed-size page views, all
/// sharing one text storage and one layout manager.
final class PageStackView: NSView, NSTextStorageDelegate {

    /// Breathing room between the paper edge and the canvas edge, so a page
    /// doesn't sit flush against the scroll view. Matches `PagedTextView`.
    static let canvasPadding: CGFloat = 16

    /// Opt-in switch for the experimental per-page editor, surfaced in Project
    /// Settings. Off means the shipping single-container editor is used.
    static let defaultsKey = "InklingUsePerPageEditor"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    let pageLayout: PagedEditorLayout
    let storage: NSTextStorage
    let sharedLayoutManager: CalloutLayoutManager

    private(set) var pageViews: [PageTextView] = []

    /// Reports a changed page count (for the editor footer), mirroring
    /// `PagedTextView.pageCountDidChange`.
    var pageCountDidChange: ((Int) -> Void)?

    /// Delegate handed to every page view, including pages added later by
    /// repagination — a page that appears mid-typing must report its edits like
    /// any other.
    weak var pageDelegate: (any NSTextViewDelegate)? {
        didSet { pageViews.forEach { $0.delegate = pageDelegate } }
    }

    /// Typing attributes applied to every page view, present and future.
    var pageTypingAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet { pageViews.forEach { $0.typingAttributes = pageTypingAttributes } }
    }

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

        // Trim trailing pages that hold no glyphs, always keeping page 1 and any
        // page that exists to hold a floating image rather than text.
        while pageViews.count > max(1, minimumPageCount),
              let last = pageViews.last?.textContainer,
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

    /// Pages that must survive trimming even with no text on them, because a
    /// floating image is parked there. Set by `rebuildFloatingImageLayout`.
    var minimumPageCount = 1

    /// The in-flight image move, if the user is dragging one.
    var moveSession: ImageMoveSession?
    /// The in-flight image resize, if the user is dragging a corner handle.
    var resizeSession: ImageResizeSession?
    /// Character index of the selected image, which shows resize handles.
    var selectedImageLocation: Int?

    // Sidebars: one child editor per anchor in the storage, hosted by the page
    // view its box lands on.
    var sidebarViews: [ObjectIdentifier: SidebarTextView] = [:]
    var sidebarAttachments: [ObjectIdentifier: SidebarAttachment] = [:]
    /// Each sidebar's page and its rect in that page's container coordinates.
    var sidebarPlacements: [ObjectIdentifier: (page: Int, rect: NSRect)] = [:]
    var selectedSidebar: ObjectIdentifier?
    var enteredSidebar: ObjectIdentifier?
    var sidebarMoveSession: SidebarDragSession?
    var sidebarResizeSession: SidebarDragSession?

    /// Caret pinned at this fraction of the viewport height when typewriter
    /// scrolling is on. Matches `PagedTextView`.
    static let typewriterAnchorFraction: CGFloat = 0.42

    var isTypewriterScrollingEnabled = false {
        didSet {
            guard isTypewriterScrollingEnabled, !oldValue else { return }
            scrollCaretToTypewriterPosition()
        }
    }

    /// One undo stack for the whole document. Each NSTextView would otherwise
    /// resolve its own through the responder chain, so an edit made on page 3
    /// could land on a different stack than one made on page 1 — and the image
    /// and sidebar gestures, which register against the stack itself, on a third.
    let sharedUndoManager = UndoManager()

    override var undoManager: UndoManager? { sharedUndoManager }

    /// Applied to every page view, including ones created later by repagination.
    /// Must not touch anything document-wide: `NSTextView.font`, for instance,
    /// restyles the whole storage, and this runs whenever a page is appended.
    var configurePage: ((PageTextView) -> Void)? {
        didSet { pageViews.forEach { configurePage?($0) } }
    }

    /// The page configuration the editor installs. Named and shared so a test
    /// can exercise the real thing: the danger here is that anything
    /// document-wide (notably `NSTextView.font`, which restyles the entire
    /// storage) silently corrupts the chapter every time repagination appends a
    /// page. A test that built its own closure would not catch that.
    static func standardPageConfiguration() -> (PageTextView) -> Void {
        { page in
            page.importsGraphics = true
            page.isContinuousSpellCheckingEnabled = true
            page.isAutomaticSpellingCorrectionEnabled = false
            page.usesAdaptiveColorMappingForDarkAppearance = false
        }
    }

    private var floatingRebuildScheduled = false

    /// Test instrumentation: how many times the floating layout has been rebuilt.
    /// Typing inside a sidebar should not move this unless the box resizes.
    private(set) var floatingLayoutRebuildCount = 0
    /// The snap guide to draw, and the page to draw it on, during a drag.
    var activeSnapGuide: HorizontalGuide?
    var activeSnapPage: Int?

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
        view.delegate = pageDelegate
        if !pageTypingAttributes.isEmpty { view.typingAttributes = pageTypingAttributes }
        // Paper is white in every appearance, so the ink must be explicitly dark.
        view.textColor = .black
        view.insertionPointColor = .black
        configurePage?(view)
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

    // MARK: - Scrolling

    /// The caret's rect in stack coordinates, wherever its page happens to be.
    func caretRectInStack() -> NSRect? {
        guard let page = focusedPageView ?? pageViews.first else { return nil }
        guard storage.length > 0, sharedLayoutManager.numberOfGlyphs > 0 else {
            // Empty document: the caret sits at the top of page 1's text column.
            let origin = page.textContainerOrigin
            return page.convert(
                NSRect(x: origin.x, y: origin.y, width: 1, height: 16), to: self
            )
        }
        let location = min(page.selectedRange().location, storage.length - 1)
        let glyph = sharedLayoutManager.glyphIndexForCharacter(at: location)
        guard glyph < sharedLayoutManager.numberOfGlyphs,
              let container = sharedLayoutManager.textContainer(
                  forGlyphAt: glyph, effectiveRange: nil
              ),
              let host = pageViews.first(where: { $0.textContainer === container })
        else { return nil }

        let lineRect = sharedLayoutManager.lineFragmentRect(
            forGlyphAt: glyph, effectiveRange: nil
        )
        return host.convert(host.viewRect(forFloating: lineRect), to: self)
    }

    /// Pins the caret at a fixed fraction of the viewport height.
    func scrollCaretToTypewriterPosition() {
        guard isTypewriterScrollingEnabled,
              let scrollView = enclosingScrollView,
              let caret = caretRectInStack()
        else { return }

        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let targetY = caret.midY - visibleHeight * Self.typewriterAnchorFraction
        let maxY = max(0, bounds.height - visibleHeight)
        clipView.setBoundsOrigin(NSPoint(
            x: clipView.bounds.origin.x,
            y: min(max(targetY, 0), maxY)
        ))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The rect for `range` in stack coordinates, on whichever page holds it.
    /// Clipped to that page's glyphs, since a range straddling a page break has
    /// no single rect.
    func rect(forCharacterRange range: NSRange) -> NSRect? {
        guard storage.length > 0, sharedLayoutManager.numberOfGlyphs > 0 else { return nil }
        let location = min(max(0, range.location), storage.length - 1)
        let glyph = sharedLayoutManager.glyphIndexForCharacter(at: location)
        guard glyph < sharedLayoutManager.numberOfGlyphs,
              let container = sharedLayoutManager.textContainer(
                  forGlyphAt: glyph, effectiveRange: nil
              ),
              let host = pageViews.first(where: { $0.textContainer === container })
        else { return nil }

        let wanted = sharedLayoutManager.glyphRange(
            forCharacterRange: NSRange(
                location: location,
                length: max(1, min(range.length, storage.length - location))
            ),
            actualCharacterRange: nil
        )
        let onThisPage = NSIntersectionRange(
            wanted, sharedLayoutManager.glyphRange(for: container)
        )
        guard onThisPage.length > 0 else { return nil }

        let bounds = sharedLayoutManager.boundingRect(forGlyphRange: onThisPage, in: container)
        return host.convert(host.viewRect(forFloating: bounds), to: self)
    }

    /// Scrolls `range` into view without disturbing the selection. This is what
    /// the find bar needs: it has already selected the match, and only wants it
    /// revealed — on whichever page actually holds it.
    func revealCharacterRange(_ range: NSRange) {
        guard range.location != NSNotFound else { return }
        if isTypewriterScrollingEnabled {
            scrollCaretToTypewriterPosition()
            return
        }
        guard let rect = rect(forCharacterRange: range) else { return }
        // A little vertical padding so a match doesn't land flush against the
        // viewport edge.
        scrollToVisible(rect.insetBy(dx: 0, dy: -60))
    }

    /// Selects `range` and scrolls it into view, whichever page it lives on.
    /// This is what outline jumps, find results, and reopen-last-position use;
    /// a page view's own `scrollRangeToVisible` only understands its container.
    func scroll(toCharacterRange range: NSRange) {
        guard range.location != NSNotFound, range.location <= storage.length else { return }
        let clamped = NSRange(
            location: range.location,
            length: min(range.length, storage.length - range.location)
        )
        guard let host = pageView(forCharacterIndex: clamped.location) else { return }
        host.setSelectedRange(clamped)
        window?.makeFirstResponder(host)
        revealCharacterRange(clamped)
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

// MARK: - Floating images
//
// This is the payoff of the whole rearchitecture. Every rectangle below is
// expressed in one coordinate space — the page's own text container, origin at
// the text column's top-left — exactly like the printer. There is no
// pre-pagination "proposed" space and no translation between spaces, so
// `PagedEditorLayout.exclusionRect` / `proposedY` and the top-of-page special
// cases they needed have no counterpart here. An image on a page's first line
// is simply an exclusion at y ≈ 0.

extension PageStackView {

    /// Where one floating image sits: which page, and its rect in that page's
    /// container coordinates.
    struct FloatingPlacement {
        let location: Int
        let page: Int
        let contentRect: NSRect
        let image: NSImage
    }

    /// Gutter between an image and the text that wraps around it. Matches the
    /// printer so screen and paper agree.
    private static let imageGutter: CGFloat = 8

    /// Converts plain image attachments into `FloatingImageAttachment`s — a tiny
    /// inline anchor in the text plus an overlay drawn by the page view — then
    /// lays them out. Mirrors `PagedTextView.prepareFloatingImages`.
    func prepareFloatingImages() {
        guard storage.length > 0 else { return }

        var replacements: [(NSRange, FloatingImageAttachment)] = []
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  !(attachment is FloatingImageAttachment),
                  !(attachment is SidebarAttachment)
            else { return }

            let size = Self.displaySize(of: attachment)
            guard size.width > 0, size.height > 0 else { return }
            let floating = FloatingImageAttachment(copying: attachment, displaySize: size)
            floating.position = storage.attribute(
                .inklingFloatingImagePosition, at: range.location, effectiveRange: nil
            ) as? FloatingImagePosition
            replacements.append((range, floating))
        }

        for (range, attachment) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            storage.addAttribute(.attachment, value: attachment, range: range)
        }
        rebuildFloatingImageLayout()
    }

    /// Coalesces a floating-layout rebuild to the next run-loop pass, so a burst
    /// of edits costs one relayout rather than one per edit.
    func scheduleFloatingRebuild() {
        guard !floatingRebuildScheduled else { return }
        floatingRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.floatingRebuildScheduled = false
            self.rebuildFloatingImageLayout()
        }
    }

    /// Recomputes every floating image's page + rect and installs the resulting
    /// exclusion paths on the page containers they belong to.
    func rebuildFloatingImageLayout() {
        floatingLayoutRebuildCount += 1
        // Start from an unwrapped baseline, so a previous exclusion can't
        // influence the anchor used to build its replacement.
        for view in pageViews {
            view.textContainer?.exclusionPaths = []
            view.floatingImages = []
        }
        minimumPageCount = 1
        rebuildPages()

        let placements = floatingPlacements()
        syncSidebarViews()
        let sidebarExclusions = layoutSidebars()

        // An image or sidebar may be parked on a page beyond where the text
        // reaches; that page has to exist, and has to survive trimming.
        let lastImagePage = placements.map(\.page).max() ?? -1
        let lastSidebarPage = sidebarPlacements.values.map(\.page).max() ?? -1
        let lastAnchoredPage = max(lastImagePage, lastSidebarPage)
        if lastAnchoredPage >= 0 {
            minimumPageCount = max(1, lastAnchoredPage + 1)
            while pageCount < minimumPageCount { appendPage() }
        }

        var exclusions = sidebarExclusions
        var drawables: [Int: [(location: Int, rect: NSRect, image: NSImage)]] = [:]
        for placement in placements {
            if let rect = FloatingImagePlacement.exclusionRect(
                contentRect: placement.contentRect,
                contentWidth: pageLayout.contentWidth,
                gutter: Self.imageGutter
            ) {
                exclusions[placement.page, default: []].append(NSBezierPath(rect: rect))
            }
            drawables[placement.page, default: []].append(
                (placement.location, placement.contentRect, placement.image)
            )
        }

        for (index, view) in pageViews.enumerated() {
            view.textContainer?.exclusionPaths = exclusions[index] ?? []
            view.floatingImages = drawables[index] ?? []
        }
        // Wrapping pushes text down, which can need another page.
        rebuildPages()
        for (index, view) in pageViews.enumerated() {
            view.floatingImages = drawables[index] ?? []
        }
        positionSidebarViews()
        needsDisplay = true
    }

    /// Resolves every floating attachment to a page and a page-local rect.
    private func floatingPlacements() -> [FloatingPlacement] {
        var placements: [FloatingPlacement] = []
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let floating = value as? FloatingImageAttachment,
                  let image = floating.image,
                  floating.displaySize.width > 0,
                  floating.displaySize.height > 0
            else { return }

            if let position = floating.position {
                // The user placed this image at a fixed spot on its page. The
                // paper origin converts straight to container coordinates.
                placements.append(FloatingPlacement(
                    location: range.location,
                    page: position.page,
                    contentRect: FloatingImagePlacement.contentRect(
                        origin: position.origin,
                        imageSize: floating.displaySize,
                        leftMargin: pageLayout.leftMargin,
                        topMargin: pageLayout.topMargin
                    ),
                    image: image
                ))
            } else if let anchored = anchoredPlacement(
                for: floating, at: range.location, image: image
            ) {
                placements.append(anchored)
            }
        }
        return placements
    }

    /// An un-placed image floats beside its anchor character's own line, so it
    /// lands where the text actually references it. The line's rect is already
    /// page-local, so this needs no translation — the case the single-container
    /// editor had to special-case and got wrong.
    private func anchoredPlacement(
        for floating: FloatingImageAttachment,
        at location: Int,
        image: NSImage
    ) -> FloatingPlacement? {
        let glyphRange = sharedLayoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0,
              let container = sharedLayoutManager.textContainer(
                  forGlyphAt: glyphRange.location, effectiveRange: nil
              ),
              let page = pageViews.firstIndex(where: { $0.textContainer === container })
        else { return nil }

        let lineRect = sharedLayoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil
        )
        // If the image can't fit in what's left of this page, park it at the top
        // of the next one rather than let it run past the bottom margin.
        let fits = lineRect.minY + floating.displaySize.height <= pageLayout.contentHeight
        let targetPage = fits ? page : page + 1
        let y = fits ? lineRect.minY : 0

        return FloatingPlacement(
            location: location,
            page: targetPage,
            contentRect: NSRect(
                x: 0,
                y: y,
                width: min(floating.displaySize.width, pageLayout.contentWidth),
                height: floating.displaySize.height
            ),
            image: image
        )
    }

    // MARK: - Dragging an image between pages
    //
    // The single-container editor had to convert a dragged point through
    // `PagedEditorLayout.position(forDisplayOrigin:size:)`, inferring the page
    // from a Y offset in a synthetic stacked space. Here the page is simply the
    // page view the cursor is over, and because each page view *is* its sheet of
    // paper, view coordinates are already paper coordinates. Dragging an image
    // onto another page is the same code path as moving it within one.

    struct ImageMoveSession {
        let location: Int
        /// Where inside the image the user grabbed, so it doesn't jump to the
        /// cursor on the first drag event.
        let grabOffset: NSSize
        let size: NSSize
        let startPosition: FloatingImagePosition?
    }

    private static let snapThreshold: CGFloat = 10

    /// Starts a move if `point` (in `pageView`'s coordinates) is on an image.
    func beginImageDrag(at point: NSPoint, in pageView: PageTextView) -> Bool {
        guard let hit = pageView.floatingImage(at: point),
              let attachment = floatingAttachment(at: hit.location)
        else { return false }

        let rect = pageView.viewRect(forFloating: hit.rect)
        moveSession = ImageMoveSession(
            location: hit.location,
            grabOffset: NSSize(width: point.x - rect.minX, height: point.y - rect.minY),
            size: attachment.displaySize,
            startPosition: attachment.position
        )
        // Pressing an image also selects it, which is what reveals the resize
        // handles for the next gesture.
        selectedImageLocation = hit.location
        pageViews.forEach { $0.needsDisplay = true }
        window?.makeFirstResponder(pageView)
        return true
    }

    /// Moves the dragged image to follow the cursor, across pages if needed.
    func continueImageDrag(with event: NSEvent) -> Bool {
        guard let session = moveSession,
              let attachment = floatingAttachment(at: session.location)
        else { return false }

        autoscroll(with: event)
        let stackPoint = convert(event.locationInWindow, from: nil)

        // Whichever page the cursor is over is the image's new page.
        let page = min(max(0, targetPage(forStackY: stackPoint.y)), max(0, pageCount - 1))
        let paper = paperFrame(forPage: page)
        var origin = CGPoint(
            x: stackPoint.x - paper.minX - session.grabOffset.width,
            y: stackPoint.y - paper.minY - session.grabOffset.height
        )

        let snap = FloatingImagePlacement.horizontalSnap(
            originX: origin.x,
            imageWidth: session.size.width,
            leftMargin: pageLayout.leftMargin,
            contentWidth: pageLayout.contentWidth,
            threshold: Self.snapThreshold
        )
        origin.x = snap.x
        activeSnapGuide = snap.guide
        activeSnapPage = page

        attachment.position = FloatingImagePosition(
            page: page,
            origin: FloatingImagePlacement.clampedOrigin(
                origin, imageSize: session.size, paperSize: pageLayout.paperSize
            )
        )
        rebuildFloatingImageLayout()
        return true
    }

    /// Commits the move, with undo, if the image actually moved. A plain click
    /// that merely lands on an image must not dirty the document.
    func endImageDrag() -> Bool {
        guard let session = moveSession else { return false }
        moveSession = nil
        activeSnapGuide = nil
        activeSnapPage = nil
        needsDisplay = true

        guard let attachment = floatingAttachment(at: session.location),
              attachment.position != session.startPosition
        else { return true }

        setFloatingPosition(attachment.position, from: session.startPosition, at: session.location)
        return true
    }

    private func setFloatingPosition(
        _ new: FloatingImagePosition?,
        from old: FloatingImagePosition?,
        at location: Int
    ) {
        guard let attachment = floatingAttachment(at: location) else { return }
        attachment.position = new
        undoManager?.registerUndo(withTarget: self) { stack in
            stack.setFloatingPosition(old, from: new, at: location)
        }
        undoManager?.setActionName("Move Image")
        rebuildFloatingImageLayout()
        // Position lives on the attachment, not in the character stream, so no
        // storage edit fires. Tell the delegate directly or the move never gets
        // encoded into the chapter's bodyData.
        pageViews.first?.didChangeText()
    }

    /// The page whose paper (or the gap below it) contains `y`.
    func targetPage(forStackY y: CGFloat) -> Int {
        max(0, Int(floor(max(0, y) / pageLayout.pageStride)))
    }

    func floatingAttachment(at location: Int) -> FloatingImageAttachment? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(
            .attachment, at: location, effectiveRange: nil
        ) as? FloatingImageAttachment
    }

    /// Draws the vertical snap guide on the page currently being dragged over.
    func drawSnapGuide(in pageView: PageTextView) {
        guard let guide = activeSnapGuide, activeSnapPage == pageView.pageIndex else { return }
        let x: CGFloat
        switch guide {
        case .left: x = pageLayout.leftMargin
        case .center: x = pageLayout.leftMargin + pageLayout.contentWidth / 2
        case .right: x = pageLayout.leftMargin + pageLayout.contentWidth
        }
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: pageLayout.topMargin))
        path.line(to: NSPoint(x: x, y: pageLayout.paperSize.height - pageLayout.bottomMargin))
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Selecting and resizing an image

    struct ImageResizeSession {
        let location: Int
        let handle: PageResizeHandle
        /// Press point, in the page view's coordinates.
        let startPoint: NSPoint
        let originalSize: NSSize
    }

    /// Clears any image selection and cancels an in-flight gesture.
    func clearImageSelection() {
        guard selectedImageLocation != nil || resizeSession != nil || moveSession != nil else {
            return
        }
        selectedImageLocation = nil
        resizeSession = nil
        moveSession = nil
        activeSnapGuide = nil
        activeSnapPage = nil
        needsDisplay = true
        pageViews.forEach { $0.needsDisplay = true }
    }

    /// The page view showing the image anchored at `location`, and that image's
    /// rect in the view's coordinates.
    func selectedImageRect(in pageView: PageTextView) -> NSRect? {
        guard let location = selectedImageLocation,
              let item = pageView.floatingImages.first(where: { $0.location == location })
        else { return nil }
        return pageView.viewRect(forFloating: item.rect)
    }

    /// Corner handles for `imageRect`, sized so they stay constant on screen
    /// regardless of the canvas magnification.
    func handleRects(for imageRect: NSRect) -> [(PageResizeHandle, NSRect)] {
        let magnification = enclosingScrollView?.magnification ?? 1
        let size = 11 / max(magnification, 0.01)
        let half = size / 2
        let points: [(PageResizeHandle, NSPoint)] = [
            (.topLeft, NSPoint(x: imageRect.minX, y: imageRect.minY)),
            (.topRight, NSPoint(x: imageRect.maxX, y: imageRect.minY)),
            (.bottomLeft, NSPoint(x: imageRect.minX, y: imageRect.maxY)),
            (.bottomRight, NSPoint(x: imageRect.maxX, y: imageRect.maxY)),
        ]
        return points.map { handle, point in
            (handle, NSRect(x: point.x - half, y: point.y - half, width: size, height: size))
        }
    }

    /// Starts a resize if `point` is on a handle of the selected image.
    func beginImageResize(at point: NSPoint, in pageView: PageTextView) -> Bool {
        guard let location = selectedImageLocation,
              let imageRect = selectedImageRect(in: pageView),
              let attachment = floatingAttachment(at: location)
        else { return false }

        // Generous slop so the small corner targets are easy to grab, scaled so
        // they stay a constant size on screen at any zoom.
        let slop = 8 / max(enclosingScrollView?.magnification ?? 1, 0.01)
        guard let handle = handleRects(for: imageRect).first(where: {
            $0.1.insetBy(dx: -slop, dy: -slop).contains(point)
        })?.0 else { return false }

        resizeSession = ImageResizeSession(
            location: location,
            handle: handle,
            startPoint: point,
            originalSize: attachment.displaySize
        )
        return true
    }

    func continueImageResize(with event: NSEvent, in pageView: PageTextView) -> Bool {
        guard let session = resizeSession else { return false }
        let point = pageView.convert(event.locationInWindow, from: nil)
        let size = ImageResizeGeometry.resizedSize(
            original: session.originalSize,
            horizontalDelta: point.x - session.startPoint.x,
            verticalDelta: point.y - session.startPoint.y,
            draggingLeftEdge: session.handle.dragsLeftEdge,
            draggingTopEdge: session.handle.dragsTopEdge,
            minimumWidth: 32,
            maximumWidth: pageLayout.contentWidth
        )
        setImageSize(size, at: session.location)
        return true
    }

    func endImageResize() -> Bool {
        guard let session = resizeSession else { return false }
        resizeSession = nil

        guard let attachment = floatingAttachment(at: session.location),
              attachment.displaySize != session.originalSize
        else { return true }

        // One undo per gesture rather than per drag event.
        let newSize = attachment.displaySize
        undoManager?.registerUndo(withTarget: self) { stack in
            stack.resizeImage(to: session.originalSize, from: newSize, at: session.location)
        }
        undoManager?.setActionName("Resize Image")
        pageViews.first?.didChangeText()
        return true
    }

    /// Undo/redo-able resize.
    private func resizeImage(to size: NSSize, from previous: NSSize, at location: Int) {
        setImageSize(size, at: location)
        undoManager?.registerUndo(withTarget: self) { stack in
            stack.resizeImage(to: previous, from: size, at: location)
        }
        undoManager?.setActionName("Resize Image")
        pageViews.first?.didChangeText()
    }

    /// Applies a new display size to a floating image and relays it out.
    func setImageSize(_ size: NSSize, at location: Int) {
        guard let attachment = floatingAttachment(at: location),
              location < storage.length
        else { return }

        attachment.displaySize = size
        attachment.image?.size = size
        // The inline anchor stays tiny — the visible image is drawn as an
        // overlay, not as a glyph.
        attachment.bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)

        // An attachment's size is measured during glyph generation and cached,
        // so mutating it in place is invisible until the glyph for this
        // character is regenerated. Replacing the attachment character (carrying
        // over its other attributes) forces TextKit to remeasure it.
        let range = NSRange(location: location, length: 1)
        var attributes = storage.attributes(at: location, effectiveRange: nil)
        attributes[.attachment] = attachment
        storage.replaceCharacters(
            in: range,
            with: NSAttributedString(string: "\u{fffc}", attributes: attributes)
        )

        rebuildFloatingImageLayout()
    }

    /// Draws the selection outline and corner handles over the selected image.
    func drawImageSelection(in pageView: PageTextView) {
        guard let imageRect = selectedImageRect(in: pageView) else { return }
        let magnification = enclosingScrollView?.magnification ?? 1

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: imageRect)
        outline.lineWidth = 2 / max(magnification, 0.01)
        outline.stroke()

        for (_, rect) in handleRects(for: imageRect) {
            NSColor.white.setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            let handle = NSBezierPath(rect: rect)
            handle.lineWidth = 1 / max(magnification, 0.01)
            handle.stroke()
        }
    }

    // MARK: - Floating margin sidebars
    //
    // Each sidebar is a child NSTextView hosted by the page view its box lands
    // on — not by the stack — so it scrolls, magnifies, and clips with its page.
    // Its exclusion is that page's local rect, the same as a floating image.

    struct SidebarDragSession {
        let id: ObjectIdentifier
        /// Press point, in the hosting page view's coordinates.
        let startPoint: NSPoint
        let startOrigin: NSPoint
        let startWidth: CGFloat
        let startPosition: FloatingImagePosition?
    }

    /// Resets sidebar hosting for a freshly loaded chapter.
    func prepareSidebars() {
        for (_, view) in sidebarViews { view.removeFromSuperview() }
        sidebarViews.removeAll()
        sidebarAttachments.removeAll()
        sidebarPlacements.removeAll()
        selectedSidebar = nil
        enteredSidebar = nil
        rebuildFloatingImageLayout()
    }

    /// Inserts an empty sidebar at the caret, on the right of its page, and
    /// enters it for typing.
    func insertSidebar() {
        let width = SidebarStyle.defaultWidth
        let caret = focusedPageView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let sidebar = SidebarAttachment(
            contentData: nil,
            width: width,
            position: defaultSidebarPosition(width: width, caret: caret.location),
            contentHeight: SidebarStyle.minContentHeight
        )
        let attributed = NSMutableAttributedString(attachment: sidebar)
        attributed.addAttributes(
            [.font: TextStyle.body.font, .foregroundColor: NSColor.black],
            range: NSRange(location: 0, length: attributed.length)
        )
        storage.replaceCharacters(in: caret, with: attributed)
        rebuildFloatingImageLayout()
        pageViews.first?.didChangeText()
        enterSidebar(ObjectIdentifier(sidebar))
    }

    /// Places a new sidebar against the right content edge, level with the
    /// caret's own line, so it lands beside where the author is writing.
    private func defaultSidebarPosition(width: CGFloat, caret: Int) -> FloatingImagePosition {
        var page = 0
        var y: CGFloat = 0
        if storage.length > 0, sharedLayoutManager.numberOfGlyphs > 0 {
            let location = min(caret, storage.length - 1)
            let glyph = sharedLayoutManager.glyphIndexForCharacter(at: location)
            if glyph < sharedLayoutManager.numberOfGlyphs,
               let container = sharedLayoutManager.textContainer(
                   forGlyphAt: glyph, effectiveRange: nil
               ),
               let index = pageViews.firstIndex(where: { $0.textContainer === container }) {
                page = index
                y = sharedLayoutManager.lineFragmentRect(
                    forGlyphAt: glyph, effectiveRange: nil
                ).minY
            }
        }
        return FloatingImagePosition(
            page: page,
            origin: CGPoint(
                x: pageLayout.leftMargin + max(0, pageLayout.contentWidth - width),
                y: pageLayout.topMargin + y
            )
        )
    }

    /// Ensures exactly one child editor per sidebar anchor in the storage.
    func syncSidebarViews() {
        var present = Set<ObjectIdentifier>()
        var attachments: [ObjectIdentifier: SidebarAttachment] = [:]
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            guard let sidebar = value as? SidebarAttachment else { return }
            let id = ObjectIdentifier(sidebar)
            present.insert(id)
            attachments[id] = sidebar
            if sidebarViews[id] == nil {
                sidebarViews[id] = makeSidebarView(for: sidebar)
            }
        }
        for (id, view) in sidebarViews where !present.contains(id) {
            view.removeFromSuperview()
            sidebarViews[id] = nil
            sidebarPlacements[id] = nil
            if selectedSidebar == id { selectedSidebar = nil }
            if enteredSidebar == id { enteredSidebar = nil }
        }
        sidebarAttachments = attachments
    }

    private func makeSidebarView(for sidebar: SidebarAttachment) -> SidebarTextView {
        let view = SidebarTextView.make(width: sidebar.width)
        view.load(sidebar.contentData)
        view.onEdited = { [weak self, weak sidebar, weak view] in
            guard let self, let sidebar, let view else { return }
            sidebar.contentData = view.contentRTF()

            // Only the box's *height* changes how body text wraps, so only a
            // height change needs a relayout. Rebuilding on every keystroke
            // relaid the whole chapter twice per character, which is unusably
            // slow on a book-length chapter.
            let height = view.fittingTextHeight()
            if abs(height - sidebar.contentHeight) > 0.5 {
                sidebar.contentHeight = height
                self.scheduleFloatingRebuild()
            }
            self.pageViews.first?.didChangeText()
        }
        view.onExit = { [weak self] in
            self?.enteredSidebar = nil
            self?.needsDisplay = true
        }
        return view
    }

    /// Resolves each sidebar to a page + page-local rect and returns the
    /// exclusion paths, keyed by page, for the body text to wrap around.
    func layoutSidebars() -> [Int: [NSBezierPath]] {
        var paths: [Int: [NSBezierPath]] = [:]
        var placements: [ObjectIdentifier: (page: Int, rect: NSRect)] = [:]

        for (id, sidebar) in sidebarAttachments {
            guard let view = sidebarViews[id] else { continue }
            view.setBoxWidth(sidebar.width)
            sidebar.contentHeight = view.fittingTextHeight()
            let size = sidebar.displaySize

            let page: Int
            let rect: NSRect
            if let position = sidebar.position {
                page = position.page
                rect = FloatingImagePlacement.contentRect(
                    origin: position.origin,
                    imageSize: size,
                    leftMargin: pageLayout.leftMargin,
                    topMargin: pageLayout.topMargin
                )
            } else {
                page = 0
                rect = NSRect(
                    x: max(0, pageLayout.contentWidth - size.width),
                    y: 0,
                    width: size.width,
                    height: size.height
                )
            }
            placements[id] = (page, rect)

            if let exclusion = FloatingImagePlacement.exclusionRect(
                contentRect: rect,
                contentWidth: pageLayout.contentWidth,
                gutter: Self.imageGutter
            ) {
                paths[page, default: []].append(NSBezierPath(rect: exclusion))
            }
        }
        sidebarPlacements = placements
        return paths
    }

    /// Parents each sidebar's child view to the page view it belongs on and
    /// frames it there. Run after pagination settles, so the target page exists.
    func positionSidebarViews() {
        for (id, placement) in sidebarPlacements {
            guard let view = sidebarViews[id],
                  placement.page < pageViews.count
            else { continue }
            let host = pageViews[placement.page]
            if view.superview !== host {
                view.removeFromSuperview()
                host.addSubview(view)
            }
            view.frame = host.viewRect(forFloating: placement.rect)
        }
    }

    /// The hosting page view and view-space rect for a sidebar.
    func sidebarViewRect(_ id: ObjectIdentifier) -> (view: PageTextView, rect: NSRect)? {
        guard let placement = sidebarPlacements[id],
              placement.page < pageViews.count
        else { return nil }
        let host = pageViews[placement.page]
        return (host, host.viewRect(forFloating: placement.rect))
    }

    func sidebarResizeHandleRect(_ viewRect: NSRect) -> NSRect {
        let magnification = enclosingScrollView?.magnification ?? 1
        let size = 11 / max(magnification, 0.01)
        return NSRect(
            x: viewRect.maxX - size / 2,
            y: viewRect.maxY - size / 2,
            width: size,
            height: size
        )
    }

    /// The sidebar whose box contains `point` on `pageView`.
    func sidebarID(at point: NSPoint, in pageView: PageTextView) -> ObjectIdentifier? {
        sidebarPlacements.first { id, placement in
            placement.page == pageView.pageIndex
                && pageView.viewRect(forFloating: placement.rect).contains(point)
        }?.key
    }

    /// True when the press was on a sidebar (select / enter / drag) or dismissed
    /// one; false lets image and text handling proceed.
    func handleSidebarMouseDown(at point: NSPoint, in pageView: PageTextView, event: NSEvent) -> Bool {
        if let id = selectedSidebar, enteredSidebar == nil,
           let sidebar = sidebarAttachments[id],
           let located = sidebarViewRect(id), located.view === pageView,
           sidebarResizeHandleRect(located.rect).insetBy(dx: -6, dy: -6).contains(point) {
            sidebarResizeSession = SidebarDragSession(
                id: id, startPoint: point, startOrigin: located.rect.origin,
                startWidth: sidebar.width, startPosition: sidebar.position
            )
            return true
        }

        if let id = sidebarID(at: point, in: pageView), let sidebar = sidebarAttachments[id] {
            if event.clickCount >= 2 {
                enterSidebar(id)
            } else {
                selectSidebar(id, in: pageView)
                sidebarMoveSession = SidebarDragSession(
                    id: id, startPoint: point,
                    startOrigin: sidebarViewRect(id)?.rect.origin ?? .zero,
                    startWidth: sidebar.width, startPosition: sidebar.position
                )
            }
            return true
        }

        if enteredSidebar != nil || selectedSidebar != nil {
            exitSidebar()
            selectedSidebar = nil
            needsDisplay = true
        }
        return false
    }

    private func selectSidebar(_ id: ObjectIdentifier, in pageView: PageTextView) {
        if let entered = enteredSidebar, entered != id { exitSidebar() }
        clearImageSelection()
        selectedSidebar = id
        window?.makeFirstResponder(pageView)
        needsDisplay = true
    }

    func enterSidebar(_ id: ObjectIdentifier) {
        guard let located = sidebarViewRect(id) else { return }
        selectSidebar(id, in: located.view)
        enteredSidebar = id
        if let view = sidebarViews[id] {
            view.isEntered = true
            window?.makeFirstResponder(view)
        }
        needsDisplay = true
    }

    func exitSidebar() {
        guard let id = enteredSidebar else { return }
        sidebarViews[id]?.isEntered = false
        enteredSidebar = nil
        if window?.firstResponder === sidebarViews[id] {
            window?.makeFirstResponder(pageViews.first)
        }
    }

    /// Moves a dragged sidebar, across pages if the cursor leaves this one.
    func continueSidebarDrag(with event: NSEvent) -> Bool {
        if let session = sidebarResizeSession, let sidebar = sidebarAttachments[session.id] {
            guard let located = sidebarViewRect(session.id) else { return true }
            let point = located.view.convert(event.locationInWindow, from: nil)
            let leftX = sidebar.position.map { $0.origin.x - pageLayout.leftMargin } ?? 0
            let maxWidth = max(SidebarStyle.minWidth, pageLayout.contentWidth - leftX)
            sidebar.width = min(
                maxWidth,
                max(SidebarStyle.minWidth, session.startWidth + (point.x - session.startPoint.x))
            )
            rebuildFloatingImageLayout()
            return true
        }

        guard let session = sidebarMoveSession,
              let sidebar = sidebarAttachments[session.id]
        else { return false }

        autoscroll(with: event)
        let stackPoint = convert(event.locationInWindow, from: nil)
        let page = min(max(0, targetPage(forStackY: stackPoint.y)), max(0, pageCount - 1))
        let paper = paperFrame(forPage: page)
        // The press point was in the old host page's coordinates, which equal
        // paper coordinates, so the grab offset carries across pages unchanged.
        var origin = CGPoint(
            x: stackPoint.x - paper.minX - (session.startPoint.x - session.startOrigin.x),
            y: stackPoint.y - paper.minY - (session.startPoint.y - session.startOrigin.y)
        )
        let snap = FloatingImagePlacement.horizontalSnap(
            originX: origin.x,
            imageWidth: sidebar.width,
            leftMargin: pageLayout.leftMargin,
            contentWidth: pageLayout.contentWidth,
            threshold: Self.snapThreshold
        )
        origin.x = snap.x
        activeSnapGuide = snap.guide
        activeSnapPage = page

        sidebar.position = FloatingImagePosition(
            page: page,
            origin: FloatingImagePlacement.clampedOrigin(
                origin, imageSize: sidebar.displaySize, paperSize: pageLayout.paperSize
            )
        )
        rebuildFloatingImageLayout()
        return true
    }

    func endSidebarDrag() -> Bool {
        let session = sidebarMoveSession ?? sidebarResizeSession
        guard let session else { return false }
        sidebarMoveSession = nil
        sidebarResizeSession = nil
        activeSnapGuide = nil
        activeSnapPage = nil
        needsDisplay = true

        guard let sidebar = sidebarAttachments[session.id],
              sidebar.position != session.startPosition || sidebar.width != session.startWidth
        else { return true }

        applySidebarGeometry(
            id: session.id, position: sidebar.position, width: sidebar.width,
            undoPosition: session.startPosition, undoWidth: session.startWidth
        )
        return true
    }

    private func applySidebarGeometry(
        id: ObjectIdentifier,
        position: FloatingImagePosition?, width: CGFloat,
        undoPosition: FloatingImagePosition?, undoWidth: CGFloat
    ) {
        guard let sidebar = sidebarAttachments[id] else { return }
        sidebar.position = position
        sidebar.width = width
        undoManager?.registerUndo(withTarget: self) { stack in
            stack.applySidebarGeometry(
                id: id, position: undoPosition, width: undoWidth,
                undoPosition: position, undoWidth: width
            )
        }
        undoManager?.setActionName("Move Sidebar")
        rebuildFloatingImageLayout()
        pageViews.first?.didChangeText()
    }

    /// Draws the selection outline and resize handle on the selected sidebar.
    func drawSidebarSelection(in pageView: PageTextView) {
        guard let id = selectedSidebar,
              let located = sidebarViewRect(id),
              located.view === pageView
        else { return }

        let magnification = enclosingScrollView?.magnification ?? 1
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: located.rect)
        outline.lineWidth = 2 / max(magnification, 0.01)
        outline.stroke()

        let handle = sidebarResizeHandleRect(located.rect)
        NSColor.white.setFill()
        handle.fill()
        NSColor.controlAccentColor.setStroke()
        let handlePath = NSBezierPath(rect: handle)
        handlePath.lineWidth = 1 / max(magnification, 0.01)
        handlePath.stroke()
    }

    static func displaySize(of attachment: NSTextAttachment) -> NSSize {
        let boundsSize = attachment.bounds.size
        if boundsSize.width > 0, boundsSize.height > 0 { return boundsSize }
        if let image = attachment.image, image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell {
            let cellSize = cell.cellSize()
            if cellSize.width > 0, cellSize.height > 0 { return cellSize }
        }
        if let data = attachment.fileWrapper?.regularFileContents,
           let image = NSImage(data: data),
           image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        return .zero
    }
}
