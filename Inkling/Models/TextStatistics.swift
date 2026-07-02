//
//  TextStatistics.swift
//  Inkling
//
//  Pure helpers for computing writing statistics. Word counting uses the
//  platform's linguistic word boundaries (so punctuation and the bullet
//  marker don't get miscounted), and page estimates use the standard
//  manuscript convention of ~250 words per page.
//

import AppKit

enum TextStatistics {

    /// Standard manuscript page ≈ 250 words.
    static let wordsPerPage = 250

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

    static func pageEstimate(forWords words: Int) -> Int {
        guard words > 0 else { return 0 }
        return Int((Double(words) / Double(wordsPerPage)).rounded(.up))
    }
}
