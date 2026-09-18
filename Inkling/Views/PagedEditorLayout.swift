//
//  PagedEditorLayout.swift
//  Inkling
//
//  Page geometry and the scrolling canvas that hosts it, shared by the per-page
//  editor (`PageStackView`) and the printer.
//
//  This file is what remains of `PagedTextView.swift`, the original
//  single-container paged editor. That view laid a whole chapter into one
//  infinitely tall text container and faked page breaks by nudging each line's
//  Y in a layout delegate, which is why floating-image exclusions had to be
//  expressed in a pre-pagination coordinate space — the root of the
//  top-of-page image bugs `PageStackView` was built to fix. `PageStackView`
//  replaced it as the shipping editor and the class itself became unreachable
//  (`RichTextEditor.makeNSView` returns the per-page editor before the branch
//  that built it), so it has been removed. Only the geometry it defined, which
//  was always shared, lives on here.
//

import AppKit


/// Keeps a full sheet of paper visible when the surrounding split view is
/// narrower than the page canvas. AppKit magnification preserves the page's
/// real TextKit measurements, which is important for matching printing later.
final class PagedEditorScrollView: NSScrollView {
    let canvasWidth: CGFloat
    private var isFittingPage = false
    private var userMagnification: CGFloat?

    init(canvasWidth: CGFloat) {
        self.canvasWidth = canvasWidth
        super.init(frame: .zero)
        allowsMagnification = true
        minMagnification = 0.2
        maxMagnification = 2.5
    }

    required init?(coder: NSCoder) {
        fatalError("PagedEditorScrollView is created programmatically")
    }

    static func fitMagnification(viewportWidth: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0, canvasWidth > 0 else { return 1 }
        return min(1, viewportWidth / canvasWidth)
    }

    override func layout() {
        super.layout()
        fitAndCenterPage()
    }

    private func fitAndCenterPage() {
        guard !isFittingPage, let documentView else { return }
        isFittingPage = true
        defer { isFittingPage = false }

        let visibleTop = contentView.bounds.minY
        let fitMagnification = max(
            minMagnification,
            Self.fitMagnification(
                viewportWidth: contentSize.width,
                canvasWidth: canvasWidth
            )
        )
        let desiredMagnification = max(fitMagnification, userMagnification ?? fitMagnification)
        if abs(magnification - desiredMagnification) > 0.001 {
            magnification = desiredMagnification
        }

        let centeredX = max(0, (documentView.bounds.width - contentView.bounds.width) / 2)
        contentView.scroll(to: NSPoint(x: centeredX, y: visibleTop))
        reflectScrolledClipView(contentView)
    }

    @objc func zoomIn(_ sender: Any?) {
        setUserMagnification(magnification * 1.15)
    }

    @objc func zoomOut(_ sender: Any?) {
        setUserMagnification(magnification / 1.15)
    }

    @objc func actualSize(_ sender: Any?) {
        setUserMagnification(1)
    }

    @objc func zoomToFit(_ sender: Any?) {
        userMagnification = nil
        fitAndCenterPage()
    }

    private func setUserMagnification(_ value: CGFloat) {
        let clamped = min(maxMagnification, max(minMagnification, value))
        userMagnification = clamped
        magnification = clamped
        fitAndCenterPage()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        userMagnification = magnification
    }
}

struct PagedEditorLayout: Equatable {
    let paperSize: NSSize
    let topMargin: CGFloat
    let bottomMargin: CGFloat
    let leftMargin: CGFloat
    let rightMargin: CGFloat
    let pageGap: CGFloat

    static let letter = PagedEditorLayout(
        paperSize: NSSize(width: 612, height: 792),
        topMargin: 72,
        bottomMargin: 72,
        leftMargin: 72,
        rightMargin: 72,
        pageGap: 24
    )

    var contentWidth: CGFloat {
        paperSize.width - leftMargin - rightMargin
    }

    var pageStride: CGFloat {
        paperSize.height + pageGap
    }

    func pageIndex(atY y: CGFloat) -> Int {
        max(0, Int(floor(max(0, y) / pageStride)))
    }

    func contentTop(forPage page: Int) -> CGFloat {
        CGFloat(page) * pageStride + topMargin
    }

    func contentBottom(forPage page: Int) -> CGFloat {
        CGFloat(page) * pageStride + paperSize.height - bottomMargin
    }

    /// Exclusion paths are evaluated before the layout delegate moves lines
    /// into page margins, so translate a displayed line back to that proposed
    /// TextKit coordinate space.
    func proposedY(forLaidOutY y: CGFloat) -> CGFloat {
        let page = pageIndex(atY: y)
        let offset = max(0, y - contentTop(forPage: page))
        if page == 0 { return offset }
        return contentBottom(forPage: page - 1) + offset
    }

    /// The exclusion rectangle that text wraps around for a floating image laid
    /// out at `imageRect` (in displayed/container coordinates).
    ///
    /// The pagination delegate only lifts the *first* line of each page into the
    /// top margin; every line below it absorbs that shift through TextKit's line
    /// stacking, so its laid-out Y already matches the coordinate space the
    /// exclusion path is evaluated in. We therefore translate the top edge back
    /// to proposed space only when the image is anchored to a page's first line.
    /// Translating unconditionally (the previous behaviour) pushed the exclusion
    /// a full top margin above any mid-page image, leaving a hole over it.
    ///
    /// On *page 0* that translated top reaches back to y=0 — before any real
    /// content exists — so stretching the rect's bottom down to the image's
    /// real (untranslated) extent is harmless, and is exactly what lets one
    /// exclusion satisfy both the pre-jump test (evaluated at the translated
    /// top) and the on-page wrap test for any later lines beside a multi-line
    /// image (evaluated at the real, untranslated position).
    ///
    /// On any *later* page, though, that translated top lands at the
    /// *previous* page's real trailing content edge (`contentBottom(page -
    /// 1)`), not at empty space. Stretching the bottom down to the image's
    /// real extent there inflates the rect by a full page's margins/gap — the
    /// two edges end up expressed in different coordinate systems within one
    /// rectangle, and the result is tall enough to reach back across the
    /// previous page's trailing content and forward across the page break.
    /// On a real manuscript that was enough to make TextKit give up on laying
    /// out the remainder of the document into one degenerate zero-size line.
    /// So past page 0, shift the bottom by the same translation as the top —
    /// trading a little wrap precision on the lines below a first-line image
    /// (rare; most floated images anchor near where the reader dragged them)
    /// for never emitting a rect that bridges two pages.
    func exclusionRect(forImageRect imageRect: NSRect, gutter: CGFloat = 8) -> NSRect {
        let page = pageIndex(atY: imageRect.minY)
        let anchorsPageFirstLine = imageRect.minY - contentTop(forPage: page) < 0.5
        let top = anchorsPageFirstLine ? proposedY(forLaidOutY: imageRect.minY) : imageRect.minY
        let rawBottom = min(imageRect.maxY + gutter, contentBottom(forPage: page))
        let bottomShift = (anchorsPageFirstLine && page > 0) ? (top - imageRect.minY) : 0
        let bottom = rawBottom + bottomShift
        return NSRect(
            x: imageRect.minX,
            y: top,
            width: min(contentWidth, imageRect.width + 10),
            height: max(0, bottom - top)
        )
    }

    /// The displayed (text-container-space) rectangle for a fixed image at
    /// `origin` (page-local paper coordinates) on `page`. Container x = 0 sits at
    /// the left content edge, so an image at paper-x `leftMargin` has container
    /// x 0; pages are stacked by `pageStride`.
    func displayRect(forPage page: Int, origin: CGPoint, size: CGSize) -> NSRect {
        NSRect(
            x: origin.x - leftMargin,
            y: CGFloat(page) * pageStride + origin.y,
            width: size.width,
            height: size.height
        )
    }

    /// Inverse of `displayRect`: the page + page-local paper origin for an image
    /// whose displayed top-left is `displayOrigin`, clamped so the whole image
    /// stays on that one page's paper.
    func position(forDisplayOrigin displayOrigin: CGPoint, size: CGSize) -> FloatingImagePosition {
        let page = pageIndex(atY: displayOrigin.y)
        let paperOrigin = CGPoint(
            x: displayOrigin.x + leftMargin,
            y: displayOrigin.y - CGFloat(page) * pageStride
        )
        let clamped = FloatingImagePlacement.clampedOrigin(
            paperOrigin, imageSize: size, paperSize: paperSize
        )
        return FloatingImagePosition(page: page, origin: clamped)
    }

    /// Moves a proposed TextKit line fragment into printable content. Lines
    /// that would cross a bottom margin move intact to the following page.
    func lineOriginY(proposedY: CGFloat, lineHeight: CGFloat) -> CGFloat {
        var page = pageIndex(atY: proposedY)
        var y = max(proposedY, contentTop(forPage: page))

        if y + lineHeight > contentBottom(forPage: page) {
            page += 1
            y = contentTop(forPage: page)
        }
        return y
    }

    func pageCount(forContentMaxY y: CGFloat) -> Int {
        max(1, pageIndex(atY: max(0, y - 0.5)) + 1)
    }

    func documentHeight(forPageCount count: Int) -> CGFloat {
        let pages = max(1, count)
        return CGFloat(pages) * paperSize.height + CGFloat(pages - 1) * pageGap
    }
}

struct ImageResizeGeometry {
    /// `maximumHeight` defaults to unbounded because most callers only know
    /// about page width (an un-positioned, anchor-line image reflows to the
    /// next page instead of overflowing vertically). Callers resizing a fixed
    /// `position`ed image — which does not reflow — must pass the page's
    /// remaining height below that position, or growth here can push the
    /// image past the page's bottom edge with no text layout able to contain
    /// it, collapsing the page (this is how a resize used to make a
    /// positioned image effectively vanish).
    static func resizedSize(
        original: NSSize,
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        draggingLeftEdge: Bool,
        draggingTopEdge: Bool,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        maximumHeight: CGFloat = .greatestFiniteMagnitude
    ) -> NSSize {
        guard original.width > 0, original.height > 0 else { return original }
        let horizontalWidth = original.width + (draggingLeftEdge ? -horizontalDelta : horizontalDelta)
        let verticalHeight = original.height + (draggingTopEdge ? -verticalDelta : verticalDelta)
        let verticalWidth = verticalHeight * original.width / original.height
        let horizontalChange = abs(horizontalWidth - original.width) / original.width
        let verticalChange = abs(verticalWidth - original.width) / original.width
        let proposedWidth = verticalChange > horizontalChange ? verticalWidth : horizontalWidth
        let heightLimitedWidth = maximumHeight * original.width / original.height
        let upperBound = min(maximumWidth, heightLimitedWidth)
        let width = min(upperBound, max(minimumWidth, proposedWidth))
        return NSSize(width: width, height: width * original.height / original.width)
    }
}
