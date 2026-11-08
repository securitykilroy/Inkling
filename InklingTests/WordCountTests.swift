//
//  WordCountTests.swift
//  InklingTests
//
//  Word counts must agree with Word's, which is what agents, editors and
//  submission guidelines use.
//

import Testing
@testable import Inkling

struct WordCountTests {

    @Test(arguments: [
        ("", 0),
        ("It was a dark night.", 5),
        ("don't can’t it's", 3),
        // Regression: each hyphenated word counted as two.
        ("a well-known, self-aware man", 4),
        ("R2-D2 and C-3PO", 3),
        ("She paused—then left.", 3),
        ("She paused — then left.", 4),
        ("brain/mind and fight/flight", 3),
        ("At 10:30 on 3/14/2024", 4),
        ("See https://example.com/a-b or me@ex.com", 4),
        ("It cost $1,000.50 or 50%.", 5),
        ("“Hello,” she said. ‘Yes.’", 4),
        ("rock & roll", 2),
        ("Wait... what?", 2),
        ("naïve café résumé", 3),
        ("•\tFirst item\n•\tSecond item", 4),
        ("Before \u{FFFC} after", 2),
        ("gen\u{FFFC}tle", 1),
        ("Chapter 1\n\nIt was a dark night.", 7),
        ("one\ttwo\u{2028}three\u{00A0}four", 4),
    ])
    func countsLikeWord(_ text: String, _ expected: Int) {
        #expect(TextStatistics.wordCount(in: text) == expected, "\(text)")
    }

    /// Languages written without spaces keep a per-word count rather than
    /// collapsing a whole sentence into one "word".
    @Test func scriptsWithoutSpacesAreStillCountedByWord() {
        #expect(TextStatistics.wordCount(in: "我喜欢读书。你呢？") > 2)
        #expect(TextStatistics.wordCount(in: "今日は、いい天気です。") > 2)
    }
}
