//
//  ChapterOutline.swift
//  Inkling
//
//  Derives an outline for a chapter by extracting its heading paragraphs from
//  the body's rich text. Headings are detected by their styling (bold + a size
//  at or above the Subheading style), since RTF doesn't preserve custom marker
//  attributes. This is intentionally heuristic and self-contained so the whole
//  outline feature can be removed cleanly if it doesn't earn its keep.
//

import AppKit

struct OutlineHeading: Identifiable, Hashable {
    let text: String
    let range: NSRange
    let level: Int
    var id: Int { range.location }
}

enum ChapterOutline {

    static func headings(in data: Data?) -> [OutlineHeading] {
        guard let attributed = RichTextCodec.decode(data),
              attributed.length > 0
        else { return [] }

        let text = attributed.string as NSString
        var headings: [OutlineHeading] = []

        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: .byParagraphs
        ) { substring, range, _, _ in
            guard let substring,
                  range.length > 0,
                  range.location < attributed.length,
                  let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                  font.fontDescriptor.symbolicTraits.contains(.bold),
                  font.pointSize >= 17
            else { return }

            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let level = font.pointSize >= 28 ? 1 : (font.pointSize >= 22 ? 2 : 3)
            headings.append(OutlineHeading(text: trimmed, range: range, level: level))
        }

        return headings
    }
}
