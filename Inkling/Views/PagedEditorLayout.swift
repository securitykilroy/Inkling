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
