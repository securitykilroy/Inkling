//
//  CalloutLayoutManager.swift
//  Inkling
//
//  Draws inline callout boxes behind the text. Used by both the on-screen editor
//  (PagedTextView) and the printer (ManuscriptPrintView) so a callout looks
//  identical on screen and on paper. The box, tint, and label are chrome — the
//  callout's text is ordinary body text tagged with `.inklingCallout`.
//

import AppKit

final class CalloutLayoutManager: NSLayoutManager {

    /// The paged editor's layout, when this manager drives the on-screen editor.
    /// Lets a callout that straddles a page break draw one box per page instead
    /// of a single box spanning the page gap. `nil` in the printer, where each
    /// page is drawn in its own container and `drawBackground` is already invoked
    /// once per page.
    var pageLayout: PagedEditorLayout?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Draw callout boxes first so the selection highlight and glyphs render
        // on top of the tint rather than being hidden behind it.
        drawCallouts(inVisibleGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawCallouts(inVisibleGlyphRange visibleGlyphs: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.inklingCallout, in: whole) { value, range, _ in
            guard let kind = (value as? String).flatMap(CalloutKind.init(storedRawValue:)) else { return }
            drawCallout(kind, characterRange: range, visibleGlyphs: visibleGlyphs, at: origin)
        }
    }

    private func drawCallout(
        _ kind: CalloutKind,
        characterRange: NSRange,
        visibleGlyphs: NSRange,
        at origin: NSPoint
    ) {
        let calloutGlyphs = glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        // Editor: draw the whole callout so a partially-scrolled box keeps its
        // true extent (anything off the dirty rect is clipped away harmlessly).
        // Printer: restrict to the page currently being drawn.
        let drawGlyphs = pageLayout == nil
            ? NSIntersectionRange(calloutGlyphs, visibleGlyphs)
            : calloutGlyphs
        guard drawGlyphs.length > 0 else { return }

        // Union the *used* (text) rects per page so each page gets its own box.
        // The full line-fragment rect includes the paragraph's reserved space
        // before/after; that space is meant to sit *outside* the box as the gap
        // to the neighbouring paragraphs, so bound the box to the glyphs only.
        var boxesByPage: [Int: NSRect] = [:]
        var containerWidth: CGFloat = 0
        enumerateLineFragments(forGlyphRange: drawGlyphs) { _, usedRect, container, _, _ in
            containerWidth = container.size.width
            let page = self.pageLayout?.pageIndex(atY: usedRect.minY) ?? 0
            boxesByPage[page] = boxesByPage[page].map { $0.union(usedRect) } ?? usedRect
        }
        guard containerWidth > 0 else { return }

        for (index, page) in boxesByPage.keys.sorted().enumerated() {
            guard let fragments = boxesByPage[page] else { continue }
            let top = fragments.minY - CalloutStyling.innerVerticalPad - CalloutStyling.labelHeight
            let bottom = fragments.maxY + CalloutStyling.innerVerticalPad
            let box = NSRect(
                x: origin.x,
                y: origin.y + top,
                width: containerWidth,
                height: bottom - top
            )
            // The label prints on the first page of a callout only.
            draw(box: box, kind: kind, showLabel: index == 0)
        }
    }

    private func draw(box: NSRect, kind: CalloutKind, showLabel: Bool) {
        let path = NSBezierPath(
            roundedRect: box,
            xRadius: CalloutStyling.cornerRadius,
            yRadius: CalloutStyling.cornerRadius
        )
        kind.fillColor.setFill()
        path.fill()
        kind.accentColor.setStroke()
        path.lineWidth = CalloutStyling.borderWidth
        path.stroke()

        guard showLabel else { return }
        let label = kind.exportLabel as NSString
        label.draw(
            at: NSPoint(x: box.minX + CalloutStyling.sideInset, y: box.minY + 3),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: kind.accentColor,
            ]
        )
    }
}
