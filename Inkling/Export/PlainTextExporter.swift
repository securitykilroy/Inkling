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

import AppKit
import Foundation

enum PlainTextExporter {

    /// Object-replacement character that stands in for an image attachment.
    nonisolated private static let attachmentMarker = "\u{fffc}"

    nonisolated static func plainText(for chapters: [PrintableChapter]) -> String {
        let blocks = chapters.map { block(for: $0) }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Title line, a blank line, then the body text. The body is included only
    /// when it has visible content so empty chapters don't trail blank lines.
    nonisolated private static func block(for chapter: PrintableChapter) -> String {
        let title = (chapter.title?.isEmpty == false) ? chapter.title! : "Untitled Chapter"

        let body = RichTextCodec.decode(chapter.bodyData).map(bodyText(from:)) ?? ""
        return body.isEmpty ? title : title + "\n\n" + body
    }

    /// The body's text with image glyphs dropped and each callout wrapped in
    /// `[LABEL] … [/LABEL]` markers, so the aside's role survives with zero
    /// formatting (e.g. for NotebookLM). Non-callout stretches are emitted as-is;
    /// callouts are separated from surrounding text by a blank line.
    nonisolated static func bodyText(from attributed: NSAttributedString) -> String {
        let attributed = expandingSidebars(attributed)
        let string = attributed.string as NSString
        var pieces: [String] = []
        attributed.enumerateAttribute(
            .inklingCallout,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            let text = string.substring(with: range)
                .replacingOccurrences(of: attachmentMarker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let kind = (value as? String).flatMap(CalloutKind.init(storedRawValue:)) {
                pieces.append("[\(kind.exportLabel)]\n\(text)\n[/\(kind.exportLabel)]")
            } else {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Replaces each floating sidebar anchor with its text wrapped in
    /// `[SIDEBAR] … [/SIDEBAR]` markers, inline where the box was anchored, so the
    /// aside's role and content survive with zero formatting.
    nonisolated private static func expandingSidebars(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        var anchors: [(range: NSRange, text: String)] = []
        mutable.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: mutable.length)
        ) { value, range, _ in
            guard let sidebar = value as? SidebarAttachment else { return }
            let text = (RichTextCodec.decode(sidebar.contentData)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            anchors.append((range, "\n[SIDEBAR]\n\(text)\n[/SIDEBAR]\n"))
        }
        // Replace back-to-front so earlier ranges stay valid.
        for anchor in anchors.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: anchor.range, with: NSAttributedString(string: anchor.text))
        }
        return mutable
    }
}
