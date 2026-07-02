//
//  PlainTextExporter.swift
//  Inkling
//
//  Flattens a project's chapters into a single plain-text manuscript. Reuses
//  PrintableChapter so export and print draw from the same chapter snapshot.
//  Rich-text formatting and embedded images are dropped: each chapter becomes
//  its title followed by the body's text, and image attachments (the U+FFFC
//  object-replacement glyph) are removed so they don't leave stray characters.
//

import Foundation

enum PlainTextExporter {

    /// Object-replacement character that stands in for an image attachment.
    private static let attachmentMarker = "\u{fffc}"

    static func plainText(for chapters: [PrintableChapter]) -> String {
        let blocks = chapters.map { block(for: $0) }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Title line, a blank line, then the body text. The body is included only
    /// when it has visible content so empty chapters don't trail blank lines.
    private static func block(for chapter: PrintableChapter) -> String {
        let title = (chapter.title?.isEmpty == false) ? chapter.title! : "Untitled Chapter"

        let body = RichTextCodec.decode(chapter.bodyData)?.string
            .replacingOccurrences(of: attachmentMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return body.isEmpty ? title : title + "\n\n" + body
    }
}
