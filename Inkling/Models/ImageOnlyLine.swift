//
//  ImageOnlyLine.swift
//  Inkling
//
//  What happens to an image that arrives on a line of its own.
//
//  Word puts a drawing in its own paragraph, so a paste or import from Word
//  produces "text\n<image>\ntext". Every image in Inkling is drawn as an
//  overlay and leaves only a 0.1pt anchor in the character stream, so that
//  paragraph is an *empty* line: the image floats beside nothing, below the
//  text that introduced it.
//
//  The anchor is therefore joined to the paragraph before it, by turning the
//  newline in front of it into a space. Three limits keep that from rewriting
//  what an author wrote:
//
//  - Only the newline *before* the image changes. The one after it stays, so
//    the paragraphs on either side of the image remain two paragraphs. (Both
//    used to become spaces, which merged them into one.)
//  - A heading is never joined to. "Chapter One / image / first paragraph"
//    used to become a single paragraph with the heading at its front.
//  - It applies only to images arriving now — pasted, dropped or imported.
//    Opening a chapter never does this: it used to run over every stored
//    image on every open, so an image an author had deliberately placed
//    between two paragraphs was pulled out of place each time, and the change
//    rode along with their next keystroke.
//
//  The replacement is one character for one, so no offset moves.
//

import AppKit

nonisolated enum ImageOnlyLine {

    /// Joins the image anchored at `location` to the paragraph before it, if
    /// it is alone on its line. Returns whether the text changed.
    @discardableResult
    static func joinToPrecedingParagraph(
        in text: NSMutableAttributedString,
        at location: Int
    ) -> Bool {
        guard location > 0, location + 1 < text.length else { return false }
        let string = text.string as NSString
        let newline: unichar = 0x0A
        guard string.character(at: location - 1) == newline,
              string.character(at: location + 1) == newline
        else { return false }

        // The paragraph the newline in front of the image ends.
        let preceding = string.paragraphRange(for: NSRange(location: location - 1, length: 0))
        // An empty line above is spacing the author (or Word) put there, with
        // nothing in it to join to.
        guard preceding.length > 1 else { return false }
        if let font = text.attribute(.font, at: preceding.location, effectiveRange: nil) as? NSFont,
           font.fontDescriptor.symbolicTraits.contains(.bold), font.pointSize >= 17 {
            return false
        }

        text.replaceCharacters(in: NSRange(location: location - 1, length: 1), with: " ")
        return true
    }

    /// Applies `joinToPrecedingParagraph` to every image in `text`. For text
    /// built offline (a Word import) before any editor sees it.
    static func joinAll(in text: NSMutableAttributedString) {
        var locations: [Int] = []
        text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard value is NSTextAttachment, !(value is SidebarAttachment) else { return }
            locations.append(contentsOf: range.location..<NSMaxRange(range))
        }
        for location in locations.reversed() {
            joinToPrecedingParagraph(in: text, at: location)
        }
    }
}
