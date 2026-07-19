//
//  TextStatistics.swift
//  Inkling
//
//  Pure helpers for computing writing statistics. Word counting uses the
//  platform's linguistic word boundaries (so punctuation and the bullet
//  marker don't get miscounted). Page counts are the real laid-out page
//  count from the editor (see `PagedTextView.pageCount(forRTF:)`), not a
//  word-based estimate, so the sidebar total matches what you see on screen.
//

import AppKit

enum TextStatistics {

    static func wordCount(in string: String) -> Int {
        let text = string as NSString
        guard text.length > 0 else { return 0 }
        var count = 0
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    static func wordCount(inRTF data: Data?) -> Int {
        guard let string = RichTextCodec.decode(data)?.string
        else { return 0 }
        return wordCount(in: string)
    }
}
