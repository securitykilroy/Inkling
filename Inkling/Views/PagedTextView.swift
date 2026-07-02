//
//  PagedTextView.swift
//  Inkling
//
//  An editable TextKit 1 view that lays rich text onto discrete paper sheets.
//  It deliberately remains an NSTextView so selection, undo, spell checking,
//  formatting, and RTF storage keep working. Floating page objects can later
//  be layered into this view and represented to TextKit as exclusion paths.
//

import AppKit

/// Keeps a full sheet of paper visible when the surrounding split view is
/// narrower than the page canvas. AppKit magnification preserves the page's
/// real TextKit measurements, which is important for matching printing later.
final class PagedEditorScrollView: NSScrollView {
    let canvasWidth: CGFloat
    private var isFittingPage = false

    init(canvasWidth: CGFloat) {
        self.canvasWidth = canvasWidth
        super.init(frame: .zero)
        allowsMagnification = true
        minMagnification = 0.2
        maxMagnification = 1
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
        let desiredMagnification = max(
            minMagnification,
            Self.fitMagnification(
                viewportWidth: contentSize.width,
                canvasWidth: canvasWidth
            )
        )
        if abs(magnification - desiredMagnification) > 0.001 {
            magnification = desiredMagnification
        }

        let centeredX = max(0, (documentView.bounds.width - contentView.bounds.width) / 2)
        contentView.scroll(to: NSPoint(x: centeredX, y: visibleTop))
        reflectScrolledClipView(contentView)
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
    /// a full top margin above any mid-page image, leaving a hole over it. The
    /// bottom edge always falls among later lines, so it needs no translation.
    func exclusionRect(forImageRect imageRect: NSRect, gutter: CGFloat = 8) -> NSRect {
        let page = pageIndex(atY: imageRect.minY)
        let anchorsPageFirstLine = imageRect.minY - contentTop(forPage: page) < 0.5
        let top = anchorsPageFirstLine ? proposedY(forLaidOutY: imageRect.minY) : imageRect.minY
        let bottom = min(imageRect.maxY + gutter, contentBottom(forPage: page))
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
    static func resizedSize(
        original: NSSize,
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        draggingLeftEdge: Bool,
        draggingTopEdge: Bool,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> NSSize {
        guard original.width > 0, original.height > 0 else { return original }
        let horizontalWidth = original.width + (draggingLeftEdge ? -horizontalDelta : horizontalDelta)
        let verticalHeight = original.height + (draggingTopEdge ? -verticalDelta : verticalDelta)
        let verticalWidth = verticalHeight * original.width / original.height
        let horizontalChange = abs(horizontalWidth - original.width) / original.width
        let verticalChange = abs(verticalWidth - original.width) / original.width
        let proposedWidth = verticalChange > horizontalChange ? verticalWidth : horizontalWidth
        let width = min(maximumWidth, max(minimumWidth, proposedWidth))
        return NSSize(width: width, height: width * original.height / original.width)
    }
}

final class PagedTextView: NSTextView, NSLayoutManagerDelegate {
    static let canvasPadding: CGFloat = 32

    let pageLayout: PagedEditorLayout
    var pageCountDidChange: ((Int) -> Void)?

    private(set) var pageCount = 1
    private var pageUpdateScheduled = false
    private var selectedImageRange: NSRange?
    private var resizeSession: ImageResizeSession?
    private var moveSession: ImageMoveSession?
    private var activeSnapGuide: HorizontalGuide?
    private var floatingImageRects: [Int: NSRect] = [:]
    private var isUpdatingFloatingLayout = false

    /// How close (in page points) the image's left edge must come to a guide
    /// before it snaps to the left / center / right of the text column.
    private static let snapThreshold: CGFloat = 10

    private enum ImageResizeHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var dragsLeftEdge: Bool {
            self == .topLeft || self == .bottomLeft
        }

        var dragsTopEdge: Bool {
            self == .topLeft || self == .topRight
        }
    }

    private struct ImageResizeSession {
        let range: NSRange
        let handle: ImageResizeHandle
        let startPoint: NSPoint
        let originalSize: NSSize
    }

    /// Tracks a drag that repositions a floating image. `startDisplayOrigin` is
    /// the image's container-space top-left when the drag began; the drag moves
    /// it by the mouse delta. `startPosition` is captured for undo (nil for an
    /// image that had not been placed yet).
    private struct ImageMoveSession {
        let range: NSRange
        let startPoint: NSPoint
        let startDisplayOrigin: NSPoint
        let size: NSSize
        let startPosition: FloatingImagePosition?
    }

    init(frame frameRect: NSRect, textContainer container: NSTextContainer, pageLayout: PagedEditorLayout) {
        self.pageLayout = pageLayout
        super.init(frame: frameRect, textContainer: container)
        layoutManager?.delegate = self
        registerForDraggedTypes([.fileURL, .png, .tiff])
        updateHorizontalInset()
    }

    required init?(coder: NSCoder) {
        fatalError("PagedTextView is created programmatically")
    }

    override func paste(_ sender: Any?) {
        let replacementStart = selectedRange().location
        super.paste(sender)

        let insertionEnd = selectedRange().location
        let pastedRange = NSRange(
            location: min(replacementStart, insertionEnd),
            length: abs(insertionEnd - replacementStart)
        )
        if RichTextImageInserter.fitOversizedAttachments(
            in: self,
            range: pastedRange,
            maximumWidth: pageLayout.contentWidth
        ) {
            didChangeText()
            updatePageLayout()
            needsDisplay = true
        }
    }

    func clearImageSelection() {
        selectedImageRange = nil
        resizeSession = nil
        moveSession = nil
        activeSnapGuide = nil
        needsDisplay = true
    }

    func prepareFloatingImages() {
        guard let storage = textStorage, storage.length > 0 else { return }
        var replacements: [(NSRange, FloatingImageAttachment)] = []
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  !(attachment is FloatingImageAttachment)
            else { return }

            let size = displaySize(of: attachment)
            guard size.width > 0, size.height > 0 else { return }
            let floating = FloatingImageAttachment(copying: attachment, displaySize: size)
            floating.position = storage.attribute(
                .inklingFloatingImagePosition,
                at: range.location,
                effectiveRange: nil
            ) as? FloatingImagePosition
            replacements.append((range, floating))
        }

        for (range, attachment) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            storage.addAttribute(.attachment, value: attachment, range: range)
            collapseImageOnlyLineBreaks(around: range.location, in: storage)
        }
        rebuildFloatingImageLayout()
    }

    private func collapseImageOnlyLineBreaks(around location: Int, in storage: NSTextStorage) {
        guard location > 0,
              location + 1 < storage.length
        else { return }

        let string = storage.string as NSString
        guard string.substring(with: NSRange(location: location - 1, length: 1)) == "\n",
              string.substring(with: NSRange(location: location + 1, length: 1)) == "\n"
        else { return }

        storage.replaceCharacters(in: NSRange(location: location + 1, length: 1), with: " ")
        storage.replaceCharacters(in: NSRange(location: location - 1, length: 1), with: " ")
    }

    private func displaySize(of attachment: NSTextAttachment) -> NSSize {
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
           image.size.width > 0,
           image.size.height > 0 {
            return image.size
        }
        return .zero
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let selectedImageRange,
           let handle = resizeHandle(at: point, for: selectedImageRange),
           let attachment = imageAttachment(at: selectedImageRange),
           shouldChangeText(in: selectedImageRange, replacementString: nil) {
            let boundsSize = (attachment as? FloatingImageAttachment)?.displaySize
                ?? attachment.bounds.size
            let originalSize = boundsSize.width > 0 && boundsSize.height > 0
                ? boundsSize
                : imageAttachmentRect(for: selectedImageRange)?.size ?? .zero
            resizeSession = ImageResizeSession(
                range: selectedImageRange,
                handle: handle,
                startPoint: point,
                originalSize: originalSize
            )
            return
        }

        if let range = imageAttachmentRange(at: point) {
            selectedImageRange = range
            setSelectedRange(range)
            window?.makeFirstResponder(self)

            // A floating image can be dragged from its body to reposition it.
            if let floating = imageAttachment(at: range) as? FloatingImageAttachment,
               let startRect = floatingImageRects[range.location] {
                moveSession = ImageMoveSession(
                    range: range,
                    startPoint: point,
                    startDisplayOrigin: startRect.origin,
                    size: floating.displaySize,
                    startPosition: floating.position
                )
            }
            needsDisplay = true
            return
        }

        clearImageSelection()
        super.mouseDown(with: event)
    }

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        if replacementString == "",
           containsProtectedFloatingImage(in: affectedCharRange) {
            return false
        }
        return super.shouldChangeText(
            in: affectedCharRange,
            replacementString: replacementString
        )
    }

    private func containsProtectedFloatingImage(in range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              range.length > 0,
              let storage = textStorage,
              NSMaxRange(range) <= storage.length,
              selectedImageRange != range
        else { return false }

        var containsFloatingImage = false
        storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value is FloatingImageAttachment {
                containsFloatingImage = true
                stop.pointee = true
            }
        }
        return containsFloatingImage
    }

    override func mouseDragged(with event: NSEvent) {
        if let session = resizeSession {
            let point = convert(event.locationInWindow, from: nil)
            let size = ImageResizeGeometry.resizedSize(
                original: session.originalSize,
                horizontalDelta: point.x - session.startPoint.x,
                verticalDelta: point.y - session.startPoint.y,
                draggingLeftEdge: session.handle.dragsLeftEdge,
                draggingTopEdge: session.handle.dragsTopEdge,
                minimumWidth: 32,
                maximumWidth: pageLayout.contentWidth
            )
            setImageAttachmentSize(size, at: session.range)
            return
        }

        if let session = moveSession {
            dragMove(session, to: convert(event.locationInWindow, from: nil))
            return
        }

        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if resizeSession != nil {
            resizeSession = nil
            didChangeText()
            updatePageLayout()
            needsDisplay = true
            return
        }

        if let session = moveSession {
            moveSession = nil
            activeSnapGuide = nil
            // Persist the move (with undo) only if the image actually moved, so a
            // plain click that merely selects an image doesn't dirty the document.
            if let attachment = imageAttachment(at: session.range) as? FloatingImageAttachment,
               attachment.position != session.startPosition {
                setFloatingPosition(attachment.position, from: session.startPosition, at: session.range)
            }
            needsDisplay = true
            return
        }

        super.mouseUp(with: event)
    }

    /// Live-updates a floating image's position as the mouse drags it: applies
    /// the mouse delta to the image's start origin, snaps the left edge to the
    /// column guides, records the active guide for drawing, and reflows text.
    private func dragMove(_ session: ImageMoveSession, to point: NSPoint) {
        var origin = NSPoint(
            x: session.startDisplayOrigin.x + (point.x - session.startPoint.x),
            y: session.startDisplayOrigin.y + (point.y - session.startPoint.y)
        )
        let paperX = origin.x + pageLayout.leftMargin
        let snap = FloatingImagePlacement.horizontalSnap(
            originX: paperX,
            imageWidth: session.size.width,
            leftMargin: pageLayout.leftMargin,
            contentWidth: pageLayout.contentWidth,
            threshold: Self.snapThreshold
        )
        origin.x = snap.x - pageLayout.leftMargin
        activeSnapGuide = snap.guide

        let position = pageLayout.position(forDisplayOrigin: origin, size: session.size)
        guard let attachment = imageAttachment(at: session.range) as? FloatingImageAttachment else { return }
        attachment.position = position
        rebuildFloatingImageLayout()
        needsDisplay = true
    }

    /// Commits a floating image's new position, registering an undo that swaps
    /// back to the previous position, and dirties the document so it re-saves.
    private func setFloatingPosition(
        _ new: FloatingImagePosition?,
        from old: FloatingImagePosition?,
        at range: NSRange
    ) {
        guard let attachment = imageAttachment(at: range) as? FloatingImageAttachment else { return }
        attachment.position = new
        undoManager?.registerUndo(withTarget: self) { view in
            view.setFloatingPosition(old, from: new, at: range)
        }
        undoManager?.setActionName("Move Image")
        rebuildFloatingImageLayout()
        updatePageLayout()
        didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFloatingImages()
        drawImageSelection()
        drawSnapGuide()
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        guard let emptyRect = emptyDocumentInsertionPointRect() else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        super.drawInsertionPoint(in: emptyRect, color: color, turnedOn: flag)
    }

    override func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let emptyRect = emptyDocumentInsertionPointRect(for: range) else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        actualRange?.pointee = NSRange(location: 0, length: 0)
        guard let window else { return emptyRect }
        return window.convertToScreen(convert(emptyRect, to: nil))
    }

    private func emptyDocumentInsertionPointRect(
        for range: NSRange? = nil
    ) -> NSRect? {
        guard (textStorage?.length ?? 0) == 0,
              selectedRange() == NSRange(location: 0, length: 0)
        else { return nil }
        if let range {
            guard range.location == 0, range.length == 0 else { return nil }
        }

        let insertionFont = (typingAttributes[.font] as? NSFont)
            ?? font
            ?? RichTextController.defaultBodyFont
        let lineHeight = layoutManager?.defaultLineHeight(for: insertionFont)
            ?? insertionFont.boundingRectForFont.height
        return NSRect(
            x: textContainerOrigin.x,
            y: textContainerOrigin.y + pageLayout.topMargin,
            width: 1,
            height: lineHeight
        )
    }

    /// Draws the alignment guide the dragged image is currently snapped to: a
    /// thin accent line down the page at the left / center / right of the text
    /// column. Only visible mid-drag.
    private func drawSnapGuide() {
        guard moveSession != nil,
              let guide = activeSnapGuide,
              let range = moveSession?.range,
              let rect = floatingImageRects[range.location]
        else { return }

        let pageLeft = max(Self.canvasPadding, (bounds.width - pageLayout.paperSize.width) / 2)
        let columnLeft = pageLeft + pageLayout.leftMargin
        let x: CGFloat
        switch guide {
        case .left: x = columnLeft
        case .center: x = columnLeft + pageLayout.contentWidth / 2
        case .right: x = columnLeft + pageLayout.contentWidth
        }

        let page = pageLayout.pageIndex(atY: rect.minY)
        let top = CGFloat(page) * pageLayout.pageStride
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: top))
        path.line(to: NSPoint(x: x, y: top + pageLayout.paperSize.height))
        path.lineWidth = 1 / max(enclosingScrollView?.magnification ?? 1, 0.01)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func imageAttachment(at range: NSRange) -> NSTextAttachment? {
        guard let storage = textStorage,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= storage.length
        else { return nil }
        return storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
    }

    func imageAttachmentRange(at point: NSPoint) -> NSRange? {
        let containerOrigin = textContainerOrigin
        for (location, rect) in floatingImageRects {
            let viewRect = rect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
            if viewRect.contains(point) {
                return NSRange(location: location, length: 1)
            }
        }

        guard let layoutManager, let textContainer, let storage = textStorage,
              layoutManager.numberOfGlyphs > 0
        else { return nil }

        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).offsetBy(dx: origin.x, dy: origin.y)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < storage.length else { return nil }
        var effectiveRange = NSRange()
        guard storage.attribute(
            .attachment,
            at: characterIndex,
            effectiveRange: &effectiveRange
        ) is NSTextAttachment else { return nil }
        return effectiveRange
    }

    func imageAttachmentRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer,
              let attachment = imageAttachment(at: range)
        else { return nil }
        if attachment is FloatingImageAttachment,
           let rect = floatingImageRects[range.location] {
            let origin = textContainerOrigin
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textContainerOrigin
        // `boundingRect` is the full line fragment, which can be taller than the
        // image (line leading). Anchor the selection rect to the line's top-left
        // and use the attachment's own size so the handles sit on the image.
        let size = attachment.bounds.size
        let imageWidth = size.width > 0 ? size.width : lineRect.width
        let imageHeight = size.height > 0 ? size.height : lineRect.height
        return NSRect(
            x: lineRect.minX + origin.x,
            y: lineRect.minY + origin.y,
            width: imageWidth,
            height: imageHeight
        )
    }

    private func handleRects(for imageRect: NSRect) -> [(ImageResizeHandle, NSRect)] {
        let magnification = enclosingScrollView?.magnification ?? 1
        let size = 11 / max(magnification, 0.01)
        let half = size / 2
        let points: [(ImageResizeHandle, NSPoint)] = [
            (.topLeft, NSPoint(x: imageRect.minX, y: imageRect.minY)),
            (.topRight, NSPoint(x: imageRect.maxX, y: imageRect.minY)),
            (.bottomLeft, NSPoint(x: imageRect.minX, y: imageRect.maxY)),
            (.bottomRight, NSPoint(x: imageRect.maxX, y: imageRect.maxY)),
        ]
        return points.map { handle, point in
            (handle, NSRect(x: point.x - half, y: point.y - half, width: size, height: size))
        }
    }

    private func resizeHandle(at point: NSPoint, for range: NSRange) -> ImageResizeHandle? {
        guard let imageRect = imageAttachmentRect(for: range) else { return nil }
        // Generous slop so the small corner handles are easy to grab, scaled so
        // the target stays a constant size on screen regardless of zoom.
        let slop = 8 / max(enclosingScrollView?.magnification ?? 1, 0.01)
        return handleRects(for: imageRect).first { $0.1.insetBy(dx: -slop, dy: -slop).contains(point) }?.0
    }

    private func drawImageSelection() {
        guard let selectedImageRange,
              let imageRect = imageAttachmentRect(for: selectedImageRange)
        else { return }

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

    func setImageAttachmentSize(_ size: NSSize, at range: NSRange) {
        guard let attachment = imageAttachment(at: range),
              let storage = textStorage
        else { return }
        if let floating = attachment as? FloatingImageAttachment {
            floating.displaySize = size
            floating.bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
        } else {
            attachment.bounds = NSRect(origin: .zero, size: size)
        }
        attachment.image?.size = size
        (attachment.attachmentCell as? NSTextAttachmentCell)?.image?.size = size
        // An attachment's size is measured during glyph generation and cached,
        // so mutating `bounds` in place is invisible until the glyph for this
        // character is regenerated. Replacing the attachment character (carrying
        // over its other attributes) forces TextKit to remeasure it.
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        attributes[.attachment] = attachment
        let replacement = NSAttributedString(string: "\u{fffc}", attributes: attributes)
        storage.replaceCharacters(in: range, with: replacement)
        rebuildFloatingImageLayout()
        updatePageLayout()
        needsDisplay = true
    }

    private func rebuildFloatingImageLayout() {
        guard !isUpdatingFloatingLayout,
              let storage = textStorage,
              let layoutManager,
              let textContainer
        else { return }

        isUpdatingFloatingLayout = true
        defer { isUpdatingFloatingLayout = false }

        // Establish every float from an unwrapped baseline. Without notifying
        // TextKit here, the previous exclusion path can influence the anchor
        // used to build its replacement and make the image drift from the
        // whitespace reserved for it.
        textContainer.exclusionPaths = []
        layoutManager.textContainerChangedGeometry(textContainer)
        let fullRange = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)

        var rects: [Int: NSRect] = [:]
        var paths: [NSBezierPath] = []
        storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            guard let floating = value as? FloatingImageAttachment,
                  floating.displaySize.width > 0,
                  floating.displaySize.height > 0
            else { return }

            let imageRect: NSRect
            if let position = floating.position {
                // The user placed this image at a fixed spot on its page.
                imageRect = pageLayout.displayRect(
                    forPage: position.page,
                    origin: position.origin,
                    size: floating.displaySize
                )
            } else {
                // Un-placed image: float it from its paragraph's first line so
                // the whole paragraph wraps beside it instead of leaving the
                // image inline midway through the text.
                let paragraphRange = (storage.string as NSString).paragraphRange(
                    for: NSRange(location: range.location, length: 0)
                )
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: paragraphRange.location, length: 1),
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { return }
                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
                // If the image can't fit in what's left of its paragraph's page
                // before the bottom margin, park it at the top of the next page
                // instead of drawing it past the page's physical edge — the same
                // rule already applied to ordinary text lines.
                let page = pageLayout.pageIndex(atY: lineRect.minY)
                let fitsRemainingPage = lineRect.minY + floating.displaySize.height
                    <= pageLayout.contentBottom(forPage: page)
                let y = fitsRemainingPage ? lineRect.minY : pageLayout.contentTop(forPage: page + 1)
                imageRect = NSRect(
                    x: 0,
                    y: y,
                    width: min(floating.displaySize.width, pageLayout.contentWidth),
                    height: floating.displaySize.height
                )
            }
            rects[range.location] = imageRect
            paths.append(NSBezierPath(
                rect: pageLayout.exclusionRect(forImageRect: imageRect)
            ))
        }

        floatingImageRects = rects
        textContainer.exclusionPaths = paths
        layoutManager.textContainerChangedGeometry(textContainer)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)
    }

    private func drawFloatingImages() {
        guard let storage = textStorage else { return }
        let origin = textContainerOrigin
        for (location, rect) in floatingImageRects where location < storage.length {
            guard let attachment = storage.attribute(
                .attachment,
                at: location,
                effectiveRange: nil
            ) as? FloatingImageAttachment,
            let image = attachment.image else { continue }
            image.draw(
                in: rect.offsetBy(dx: origin.x, dy: origin.y),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }

    static func draggedImage(from pasteboard: NSPasteboard) -> NSImage? {
        if let image = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        )?.first as? NSImage {
            return image
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let url = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        )?.first as? URL else { return nil }
        return NSImage(contentsOf: url)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.draggedImage(from: sender.draggingPasteboard) == nil
            ? super.draggingEntered(sender)
            : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = Self.draggedImage(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }

        let viewPoint = convert(sender.draggingLocation, from: nil)
        let insertionRange = imageInsertionRange(at: viewPoint)
        return RichTextImageInserter.insert(
            image,
            into: self,
            at: insertionRange,
            maximumWidth: pageLayout.contentWidth
        )
    }

    private func imageInsertionRange(at viewPoint: NSPoint) -> NSRange {
        guard let layoutManager, let textContainer else {
            return selectedRange()
        }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(
            x: viewPoint.x - origin.x,
            y: viewPoint.y - origin.y
        )
        let index = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return NSRange(location: min(index, textStorage?.length ?? 0), length: 0)
    }

    static func makePagedScrollView(pageLayout: PagedEditorLayout = .letter) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: pageLayout.contentWidth,
            height: .greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let minimumWidth = pageLayout.paperSize.width + canvasPadding * 2
        let textView = PagedTextView(
            frame: NSRect(x: 0, y: 0, width: minimumWidth, height: pageLayout.paperSize.height),
            textContainer: container,
            pageLayout: pageLayout
        )
        textView.minSize = NSSize(width: minimumWidth, height: pageLayout.paperSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.appearance = NSAppearance(named: .aqua)
        // Cmd-F / Edit ▸ Find drives the standard TextKit find bar, which the
        // enclosing scroll view hosts. Incremental search highlights matches as
        // the user types in the bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let scrollView = PagedEditorScrollView(canvasWidth: minimumWidth)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.contentInsets = NSEdgeInsets(top: 24, left: 0, bottom: 24, right: 0)
        return scrollView
    }

    override func setFrameSize(_ newSize: NSSize) {
        let minimumWidth = pageLayout.paperSize.width + Self.canvasPadding * 2
        let pageHeight = pageLayout.documentHeight(forPageCount: pageCount)
        super.setFrameSize(NSSize(
            width: max(minimumWidth, newSize.width),
            height: max(pageHeight, newSize.height)
        ))
        updateHorizontalInset()
    }

    func updatePageLayout() {
        guard let layoutManager, let textContainer else { return }
        rebuildFloatingImageLayout()
        layoutManager.ensureLayout(for: textContainer)
        let floatingBottom = floatingImageRects.values.map(\.maxY).max() ?? 0
        let newPageCount = pageLayout.pageCount(forContentMaxY: max(
            layoutManager.usedRect(for: textContainer).maxY,
            floatingBottom
        ))

        if newPageCount != pageCount {
            pageCount = newPageCount
            pageCountDidChange?(newPageCount)
        }

        let viewportHeight = enclosingScrollView?.contentSize.height ?? 0
        let desiredHeight = max(
            viewportHeight,
            pageLayout.documentHeight(forPageCount: newPageCount)
        )
        if abs(frame.height - desiredHeight) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: desiredHeight))
        }
        needsDisplay = true
    }

    private func updateHorizontalInset() {
        let pageLeft = max(Self.canvasPadding, (bounds.width - pageLayout.paperSize.width) / 2)
        let inset = pageLeft + pageLayout.leftMargin
        if abs(textContainerInset.width - inset) > 0.5 || textContainerInset.height != 0 {
            textContainerInset = NSSize(width: inset, height: 0)
        }
    }

    private func schedulePageUpdate() {
        guard !pageUpdateScheduled else { return }
        pageUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pageUpdateScheduled = false
            self.updatePageLayout()
        }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let oldY = lineFragmentRect.pointee.minY
        let lineHeight = max(lineFragmentRect.pointee.height, lineFragmentUsedRect.pointee.height)
        let newY = pageLayout.lineOriginY(proposedY: oldY, lineHeight: lineHeight)
        let delta = newY - oldY
        guard abs(delta) > 0.01 else { return false }

        lineFragmentRect.pointee.origin.y += delta
        lineFragmentUsedRect.pointee.origin.y += delta

        let oldPage = pageLayout.pageIndex(atY: oldY)
        let newPage = pageLayout.pageIndex(atY: newY)
        if newPage != oldPage, !pageHasImageAnchoredToItsFirstLine(newPage) {
            // TextKit tests this line's shape against the container's exclusion
            // paths *before* we lift it onto the new page above, using a raw,
            // continuous Y that (because proposed-space layout has no page
            // breaks) lands in the same numeric neighborhood as the previous
            // page's trailing content. A floating image parked near the bottom
            // of that previous page can therefore squeeze what turns out to be
            // the next page's first line, even though the image never appears
            // on that page. Since this page has no image of its own anchored to
            // its first line, undo that false-positive squeeze.
            let xDelta = -lineFragmentRect.pointee.origin.x
            lineFragmentRect.pointee.origin.x = 0
            lineFragmentRect.pointee.size.width = pageLayout.contentWidth
            lineFragmentUsedRect.pointee.origin.x += xDelta
        }
        return true
    }

    /// Whether `page` has a floating image whose displayed rect starts flush
    /// with that page's first line (the one case where TextKit's exclusion
    /// test is intentionally translated to match, in `PagedEditorLayout.
    /// exclusionRect(forImageRect:)`), so a squeezed first line there is
    /// legitimate rather than spillover from a preceding page's image.
    private func pageHasImageAnchoredToItsFirstLine(_ page: Int) -> Bool {
        let top = pageLayout.contentTop(forPage: page)
        return floatingImageRects.values.contains { abs($0.minY - top) < 0.5 }
    }

    func layoutManagerDidInvalidateLayout(_ sender: NSLayoutManager) {
        guard !isUpdatingFloatingLayout else { return }
        schedulePageUpdate()
    }

    override func drawBackground(in rect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        rect.fill()

        let pageLeft = max(Self.canvasPadding, (bounds.width - pageLayout.paperSize.width) / 2)
        for page in 0..<pageCount {
            let pageRect = NSRect(
                x: pageLeft,
                y: CGFloat(page) * pageLayout.pageStride,
                width: pageLayout.paperSize.width,
                height: pageLayout.paperSize.height
            )
            guard pageRect.intersects(rect) else { continue }

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(rect: pageRect).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: pageRect).stroke()
        }
    }
}
