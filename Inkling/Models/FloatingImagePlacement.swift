//
//  FloatingImagePlacement.swift
//  Inkling
//
//  Pure geometry for a floating image that is fixed on a page. Positions are
//  expressed in page-local paper coordinates (points from the page's top-left
//  paper corner, y increasing downward to match the flipped text views). The
//  same math is shared by the on-screen editor and the printer so an image
//  lands identically in both. UI-framework-free so it can be unit tested.
//

import CoreGraphics

/// A floating image's fixed placement: which page it lives on, and the top-left
/// corner of the image in that page's paper coordinates.
struct FloatingImagePosition: Equatable {
    var page: Int
    var origin: CGPoint
}

/// Which vertical guide a dragged image snapped to, for drawing the guide line.
enum HorizontalGuide: Equatable {
    case left, center, right
}

enum FloatingImagePlacement {

    /// Keep the whole image within the paper. If the image is larger than the
    /// paper on an axis, that axis clamps to 0.
    static func clampedOrigin(
        _ origin: CGPoint,
        imageSize: CGSize,
        paperSize: CGSize
    ) -> CGPoint {
        let maxX = max(0, paperSize.width - imageSize.width)
        let maxY = max(0, paperSize.height - imageSize.height)
        return CGPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
    }

    /// The image rectangle relative to the page's content-area (text column)
    /// top-left. Negative x/y means the image extends into a margin.
    static func contentRect(
        origin: CGPoint,
        imageSize: CGSize,
        leftMargin: CGFloat,
        topMargin: CGFloat
    ) -> CGRect {
        CGRect(
            x: origin.x - leftMargin,
            y: origin.y - topMargin,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    /// The rectangle text should avoid, clipped to the text column
    /// `[0, contentWidth]` and grown by `gutter` so text keeps a small gap.
    /// Returns nil when the image doesn't overlap the text column at all
    /// (e.g. parked entirely in a side margin), so no exclusion is needed.
    static func exclusionRect(
        contentRect: CGRect,
        contentWidth: CGFloat,
        gutter: CGFloat
    ) -> CGRect? {
        let grown = contentRect.insetBy(dx: -gutter, dy: -gutter)
        let minX = max(0, grown.minX)
        let maxX = min(contentWidth, grown.maxX)
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: grown.minY, width: maxX - minX, height: grown.height)
    }

    /// Snap the image's left edge toward the left content edge, the horizontal
    /// center of the column, or the right content edge when within `threshold`.
    /// Returns the (possibly unchanged) x and the guide that was hit, if any.
    static func horizontalSnap(
        originX: CGFloat,
        imageWidth: CGFloat,
        leftMargin: CGFloat,
        contentWidth: CGFloat,
        threshold: CGFloat
    ) -> (x: CGFloat, guide: HorizontalGuide?) {
        let targets: [(HorizontalGuide, CGFloat)] = [
            (.left, leftMargin),
            (.center, leftMargin + (contentWidth - imageWidth) / 2),
            (.right, leftMargin + contentWidth - imageWidth),
        ]
        let nearest = targets.min { abs($0.1 - originX) < abs($1.1 - originX) }
        if let nearest, abs(nearest.1 - originX) <= threshold {
            return (nearest.1, nearest.0)
        }
        return (originX, nil)
    }
}
