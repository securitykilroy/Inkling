//
//  ImageCaption.swift
//  Inkling
//
//  A short line of plain text printed beneath a floating image.
//
//  The caption belongs to its image: it moves, wraps, and is deleted with it.
//  For layout the two act as one object, so text wraps around the image *and*
//  its caption, and the pair is kept on one page together. Hit-testing and the
//  resize handles still use the image alone.
//
//  The editor (`PageStackView`) and the printer (`ManuscriptPrintView`) both
//  measure and draw captions through this file, so screen and paper agree.
//

import AppKit

extension NSAttributedString.Key {
    /// Carries an image's caption from `RichTextCodec.decode` to the code that
    /// lays images out (the editor and the printer), like
    /// `.inklingFloatingImagePosition`. In memory only; the caption is stored
    /// in the codec's attachment sidecar, not in the RTFD text.
    nonisolated static let inklingImageCaption = NSAttributedString.Key("inklingImageCaption")
}

enum ImageCaption {

    /// Space between the bottom of the image and the caption's first line.
    static let gap: CGFloat = 4
    static let pointSize: CGFloat = 10
    /// Dark grey rather than black, so a caption reads as secondary to the
    /// prose. Paper is white in the editor in both appearances, so a fixed
    /// colour is right on screen as well as in print.
    static let color = NSColor(white: 0.3, alpha: 1)

    /// The caption worth storing: trimmed, with an empty one meaning none.
    nonisolated static func normalized(_ caption: String?) -> String? {
        guard let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Small italic in the family of the text around the image, so a caption
    /// follows the project's body font without the layout code having to know
    /// what that font is.
    static func font(near textFont: NSFont?) -> NSFont {
        let family = textFont?.familyName ?? NSFont.systemFont(ofSize: pointSize).familyName ?? ""
        let manager = NSFontManager.shared
        if let italic = manager.font(withFamily: family, traits: .italicFontMask, weight: 5, size: pointSize),
           manager.traits(of: italic).contains(.italicFontMask) {
            return italic
        }
        let plain = NSFont(name: textFont?.fontName ?? "", size: pointSize) ?? NSFont.systemFont(ofSize: pointSize)
        return manager.convert(plain, toHaveTrait: .italicFontMask)
    }

    static func attributedString(_ caption: String, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: caption, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// Height the caption adds below an image `width` wide, gap included; zero
    /// for no caption.
    static func height(of caption: String?, width: CGFloat, font: NSFont) -> CGFloat {
        guard let caption = normalized(caption), width > 0 else { return 0 }
        let bounds = attributedString(caption, font: font).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return gap + ceil(bounds.height)
    }

    /// Where the caption text goes, given the image's rect (y grows downward)
    /// and the height `height(of:width:font:)` returned.
    static func textRect(below imageRect: NSRect, height: CGFloat) -> NSRect {
        NSRect(
            x: imageRect.minX,
            y: imageRect.maxY + gap,
            width: imageRect.width,
            height: max(0, height - gap)
        )
    }

    /// Draws the caption into `rect` in a flipped view.
    static func draw(_ caption: String, in rect: NSRect, font: NSFont) {
        attributedString(caption, font: font).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}
