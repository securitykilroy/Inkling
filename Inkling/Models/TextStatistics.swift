//
//  TextStatistics.swift
//  Inkling
//
//  Pure helpers for computing writing statistics. Word counts follow Word's
//  convention (see `wordCount(in:)`). Page counts are the real laid-out page
//  count from the editor (see `PageStackView.pageCount(forRTF:)`), not a
//  word-based estimate, so the sidebar total matches what you see on screen.
//

import AppKit

enum TextStatistics {

    /// Counts words the way Word does, which is the count agents, editors
    /// and submission guidelines go by: a word is a run of text between
    /// spaces. The platform's word boundaries find the words (so stray
    /// punctuation and the bullet marker aren't counted), then words joined
    /// with no space between them, as in "well-known", "brain/mind" or
    /// "10:30", are counted once. Counting those boundaries alone counted
    /// each hyphenated word twice, about 0.5% high on a real manuscript.
    ///
    /// Scripts written without spaces (Chinese, Japanese, Thai) keep the
    /// platform's per-word count: their words are never joined.
    static func wordCount(in string: String) -> Int {
        let text = string as NSString
        guard text.length > 0 else { return 0 }
        var count = 0
        var previousEnd: Int?
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byWords, .localized, .substringNotRequired]
        ) { _, range, _, _ in
            defer { previousEnd = NSMaxRange(range) }
            if let previousEnd, range.location > previousEnd,
               joinsWords(text.substring(
                   with: NSRange(location: previousEnd, length: range.location - previousEnd)
               )) {
                return
            }
            count += 1
        }
        return count
    }

    /// Whether the text between two words leaves them one word: it has no
    /// space or line break, and isn't punctuation from a script that doesn't
    /// use spaces (where "。" or "、" separate words). An image anchor inside
    /// a word doesn't split it.
    private static func joinsWords(_ gap: String) -> Bool {
        gap.unicodeScalars.allSatisfy { scalar in
            if scalar == "\u{FFFC}" { return true }
            return scalar.value < 0x2E80
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    /// A chapter's words: its body plus the text and titles of its sidebar
    /// boxes, which are part of the manuscript (they print and export).
    /// Image captions aren't counted. They're stored as attributes, not text,
    /// so the body string never contains them.
    static func wordCount(inRTF data: Data?) -> Int {
        guard let decoded = RichTextCodec.decodeTextAndSidebars(data) else { return 0 }
        return decoded.sidebars.reduce(wordCount(in: decoded.text.string)) {
            $0 + sidebarWordCount(title: $1.title, content: $1.content)
        }
    }

    /// The live count for the chapter being edited: the editor's text, with
    /// each sidebar box's words read from its attachment.
    static func wordCount(in text: NSAttributedString) -> Int {
        var count = wordCount(in: text.string)
        text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: text.length)
        ) { value, _, _ in
            guard let sidebar = value as? SidebarAttachment else { return }
            count += sidebarWordCount(title: sidebar.title, content: sidebar.contentData)
        }
        return count
    }

    /// An empty title shows the default header, which the writer didn't type
    /// and isn't counted.
    private static func sidebarWordCount(title: String, content: Data?) -> Int {
        wordCount(in: title) + wordCount(in: RichTextCodec.decodeText(content)?.string ?? "")
    }
}
