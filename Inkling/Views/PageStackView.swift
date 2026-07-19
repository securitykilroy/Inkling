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

    private var stack: PageStackView? { superview as? PageStackView }

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
        stack?.drawSnapGuide(in: self)
    }

    // MARK: - Image dragging
    //
    // The drag session lives on the stack, not here, because a drag can carry an
    // image onto a different page — and therefore into a different view — partway
    // through. The stack owns the coordinate conversion.

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Handles first: they sit on the image's corners and extend past its
        // edge, so an image hit test would otherwise swallow them.
        if stack?.beginImageResize(at: point, in: self) == true { return }
        if stack?.beginImageDrag(at: point, in: self) == true { return }
        stack?.clearImageSelection()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if stack?.continueImageResize(with: event, in: self) == true { return }
        if stack?.continueImageDrag(with: event) == true { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if stack?.endImageResize() == true { return }
        if stack?.endImageDrag() == true { return }
        super.mouseUp(with: event)
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

    /// Recomputes every floating image's page + rect and installs the resulting
    /// exclusion paths on the page containers they belong to.
    func rebuildFloatingImageLayout() {
        // Start from an unwrapped baseline, so a previous exclusion can't
        // influence the anchor used to build its replacement.
        for view in pageViews {
            view.textContainer?.exclusionPaths = []
            view.floatingImages = []
        }
        minimumPageCount = 1
        rebuildPages()

        let placements = floatingPlacements()

        // An image may be parked on a page beyond where the text reaches; that
        // page has to exist, and has to survive trimming.
        if let lastImagePage = placements.map(\.page).max() {
            minimumPageCount = max(1, lastImagePage + 1)
            while pageCount < minimumPageCount { appendPage() }
        }

        var exclusions: [Int: [NSBezierPath]] = [:]
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
