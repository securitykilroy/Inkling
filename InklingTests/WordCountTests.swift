//
//  WordCountTests.swift
//  InklingTests
//
//  Word counts must agree with Word's, which is what agents, editors and
//  submission guidelines use.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
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

    private func chapterWithSidebar(title: String) -> NSAttributedString {
        let sidebar = SidebarAttachment(
            contentData: RichTextCodec.encode(NSAttributedString(string: "Three sidebar words")),
            width: 160, position: nil, contentHeight: 40
        )
        sidebar.title = title
        let text = NSMutableAttributedString(string: "Body has four words. ")
        text.append(NSAttributedString(attachment: sidebar))
        text.append(NSAttributedString(string: " And two."))
        return text
    }

    /// Sidebar boxes are manuscript text, so they count, in both the stored
    /// count and the live one the editor reports while typing.
    @Test func sidebarTextAndTitlesCount() throws {
        let untitled = chapterWithSidebar(title: "")
        #expect(TextStatistics.wordCount(in: untitled) == 9)
        #expect(TextStatistics.wordCount(inRTF: RichTextCodec.encode(untitled)) == 9)

        let titled = chapterWithSidebar(title: "Did you know?")
        #expect(TextStatistics.wordCount(in: titled) == 12)
        let stored = try #require(RichTextCodec.encode(titled))
        #expect(TextStatistics.wordCount(inRTF: stored) == 12)
        // Same answer from the editor's copy of the decoded chapter.
        #expect(TextStatistics.wordCount(in: try #require(RichTextCodec.decode(stored))) == 12)
    }

    /// Image captions aren't counted.
    @Test func captionsDontCount() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let attachment = NSTextAttachment(data: png, ofType: "public.png")
        let text = NSMutableAttributedString(string: "Two words ")
        text.append(NSAttributedString(attachment: attachment))
        text.addAttribute(
            .inklingImageCaption, value: "A caption of six words here",
            range: NSRange(location: text.length - 1, length: 1)
        )
        #expect(TextStatistics.wordCount(in: text) == 2)
        #expect(TextStatistics.wordCount(inRTF: RichTextCodec.encode(text)) == 2)
    }
}
