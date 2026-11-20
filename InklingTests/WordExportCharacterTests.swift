//
//  WordExportCharacterTests.swift
//  InklingTests
//
//  XML 1.0 — which a .docx's parts must be — forbids most control
//  characters outright. One of them in a chapter (a vertical tab or form feed
//  from text pasted out of Word, a stray bell from a terminal) made the export
//  a file Word refuses to open as corrupt.
//

import AppKit
import Testing
@testable import Inkling

@MainActor
struct WordExportCharacterTests {

    private static func documentXML(forBody text: String) throws -> String {
        let body = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let data = try #require(RichTextCodec.encode(body))
        // Only meaningful if the control characters survive storage; otherwise
        // the export never sees them and the test passes for the wrong reason.
        let stored = try #require(RichTextCodec.decode(data)).string
        #expect(stored.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })

        let docx = try WordDocumentExporter.docxData(for: PrintableChapter(title: "Ch", bodyData: data))
        let reader = try MinimalZipReader(data: docx)
        return try #require(String(data: reader.contents(of: "word/document.xml"), encoding: .utf8))
    }

    @Test func controlCharactersStillGiveWellFormedXML() throws {
        let xml = try Self.documentXML(forBody: "Bell\u{07} back\u{08}space esc\u{1B} unit\u{1F} end.")
        #expect(throws: Never.self) { try XMLDocument(xmlString: xml) }
        #expect(xml.contains("Bell back"))
        #expect(xml.contains("end."))
    }

    /// Word's own meanings for these two, so they round-trip as what the
    /// author saw rather than vanishing.
    @Test func verticalTabIsALineBreakAndFormFeedAPageBreak() throws {
        let xml = try Self.documentXML(forBody: "One\u{0B}two\u{0C}three")
        #expect(throws: Never.self) { try XMLDocument(xmlString: xml) }
        #expect(xml.contains(#"One</w:t><w:br/>"#))
        #expect(xml.contains(#"<w:br w:type="page"/>"#))
    }

    /// Titles, captions and sidebar labels go through the same escaping.
    @Test func escapingDropsCharactersXMLForbids() {
        #expect(WordDocumentExporter.escapeXML("a\u{07}b<c\u{0}d\u{FFFE}e") == "ab&lt;cde")
        #expect(WordDocumentExporter.escapeXML("tab\tline\nok") == "tab\tline\nok")
    }
}
