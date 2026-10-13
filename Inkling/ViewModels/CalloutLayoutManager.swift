//
//  CalloutLayoutManager.swift
//  Inkling
//
//  Draws inline callout boxes behind the text. Used by both the on-screen editor
//  (PageStackView) and the printer (ManuscriptPrintView) so a callout looks
//  identical on screen and on paper. The box, tint, and label are chrome — the
//  callout's text is ordinary body text tagged with `.inklingCallout`.
//

import AppKit

final class CalloutLayoutManager: NSLayoutManager {

    /// One callout box to draw: a callout's share of one page.
    struct CalloutBox: Equatable {
        let kind: CalloutKind
        /// In the coordinates of the container being drawn, before `origin`.
        let rect: NSRect
        /// The label goes on the page where the callout starts, not on every
        /// page it continues onto.
        let showsLabel: Bool
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Draw callout boxes first so the selection highlight and glyphs render
        // on top of the tint rather than being hidden behind it.
        for box in calloutBoxes(forGlyphRange: glyphsToShow) {
            draw(box: box.rect.offsetBy(dx: origin.x, dy: origin.y), kind: box.kind, showLabel: box.showsLabel)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// The callout boxes to draw for a redraw of `visibleGlyphs`.
    ///
    /// Both the editor and the printer give each page its own text container
    /// and draw one page at a time. Each box is bounded by the page being
    /// drawn — its whole container, not just the glyphs being redrawn, or a
    /// partial redraw would draw a box cut short — so a callout that crosses a
    /// page break gets one box per page.
    func calloutBoxes(forGlyphRange visibleGlyphs: NSRange) -> [CalloutBox] {
        guard let storage = textStorage, storage.length > 0, visibleGlyphs.length > 0,
              let container = textContainer(forGlyphAt: visibleGlyphs.location, effectiveRange: nil)
        else { return [] }
        let pageGlyphs = glyphRange(for: container)

        var boxes: [CalloutBox] = []
        storage.enumerateAttribute(
            .inklingCallout, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let kind = (value as? String).flatMap(CalloutKind.init(storedRawValue:)) else { return }
            let calloutGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard NSIntersectionRange(calloutGlyphs, visibleGlyphs).length > 0 else { return }
            let drawGlyphs = NSIntersectionRange(calloutGlyphs, pageGlyphs)
            guard drawGlyphs.length > 0 else { return }

            // Union the *used* (text) rects for the box. The full line-fragment
            // rect includes the paragraph's reserved space before/after; that
            // space is meant to sit *outside* the box as the gap to the
            // neighbouring paragraphs, so bound the box to the glyphs only.
            var fragments: NSRect?
            enumerateLineFragments(forGlyphRange: drawGlyphs) { _, usedRect, _, _, _ in
                fragments = fragments.map { $0.union(usedRect) } ?? usedRect
            }
            guard let fragments, container.size.width > 0 else { return }

            let top = fragments.minY - CalloutStyling.innerVerticalPad - CalloutStyling.labelHeight
            let bottom = fragments.maxY + CalloutStyling.innerVerticalPad
            boxes.append(CalloutBox(
                kind: kind,
                rect: NSRect(x: 0, y: top, width: container.size.width, height: bottom - top),
                showsLabel: drawGlyphs.location == calloutGlyphs.location
            ))
        }
        return boxes
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
