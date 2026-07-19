//
//  SidebarBox.swift
//  Inkling
//
//  A floating margin sidebar: a narrow, bordered text box the body text wraps
//  around, placed on a page like a floating image but holding its own editable
//  text. `SidebarAttachment` is the invisible anchor that lives in the body text
//  stream (so the box has a home in the flow and survives copy/paste); the box's
//  content, page position, and width ride in the RTFD sidecar via RichTextCodec.
//
//  Reuses `FloatingImagePosition` for placement so the on-screen editor and the
//  printer share one coordinate system, exactly like floating images.
//

import AppKit

/// Fixed visual style + geometry for the floating sidebar box, shared by the
/// editable child view (`SidebarTextView`) and the printer so a sidebar looks
/// identical on screen and on paper.
enum SidebarStyle {
    static let headerLabel = "SIDEBAR"
    static let accentHex = "6B7280"
    static let fillHex = "F3F4F6"

    static var accentColor: NSColor { NSColor(inklingHex: accentHex) }
    static var fillColor: NSColor { NSColor(inklingHex: fillHex) }

    /// Height of the "SIDEBAR" header band at the top of the box.
    static let headerHeight: CGFloat = 22
    /// Padding around the text inside the box.
    static let padding: CGFloat = 10
    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 1.5

    static let defaultWidth: CGFloat = 220
    static let minWidth: CGFloat = 130
    /// Fallback text height for a brand-new, empty box before its child view has
    /// measured real content.
    static let minContentHeight: CGFloat = 20

    /// Width available to the sidebar's text inside its padding.
    static func textWidth(forBoxWidth width: CGFloat) -> CGFloat {
        max(20, width - padding * 2)
    }

    /// Total box height for a measured text height.
    static func boxHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        headerHeight + padding + max(minContentHeight, contentHeight) + padding
    }
}

/// The anchor for a floating sidebar. Like `FloatingImageAttachment`, its inline
/// bounds collapse to a point so it never disturbs the line it sits on; the
/// visible box is drawn/hosted separately by `PagedTextView` and the printer.
final class SidebarAttachment: NSTextAttachment {
    /// The sidebar's rich text, as RTF.
    var contentData: Data?
    /// Fixed page placement (page + top-left in paper coordinates). New sidebars
    /// are placed immediately on insert, so this is effectively always set.
    var position: FloatingImagePosition?
    /// Box width in points (author-adjustable via resize handles).
    var width: CGFloat
    /// Last measured text height, so layout has a size before the child view
    /// re-measures. Kept current by `PagedTextView` as the box's text changes.
    var contentHeight: CGFloat

    init(contentData: Data?, width: CGFloat, position: FloatingImagePosition?, contentHeight: CGFloat) {
        self.contentData = contentData
        self.width = width
        self.position = position
        self.contentHeight = contentHeight
        super.init(data: nil, ofType: nil)
        // A 1×1 transparent image collapsed to 0.1pt makes the in-flow anchor
        // invisible: with an image set, TextKit sizes/draws the image (nothing)
        // instead of falling back to a generic file-icon cell. It also carries
        // the U+FFFC anchor character through RTFD encoding. The sidebar's real
        // content + geometry ride in the sidecar, keyed by this anchor's location.
        image = Self.invisibleAnchorImage
        attachmentCell = nil
        bounds = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
    }

    required init?(coder: NSCoder) {
        width = SidebarStyle.defaultWidth
        contentHeight = SidebarStyle.minContentHeight
        super.init(coder: coder)
    }

    /// The box's full display size for the current width + measured content.
    var displaySize: NSSize {
        NSSize(width: width, height: SidebarStyle.boxHeight(forContentHeight: contentHeight))
    }

    private static let invisibleAnchorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }()
}
