//
//  WordDocumentImporter.swift
//  Inkling
//
//  Converts a .docx file's body into an NSAttributedString suitable for a
//  Chapter's bodyData. Reads word/document.xml directly (via MinimalZipReader
//  + XMLDocument) rather than going through the pasteboard/RTF, because
//  Apple's built-in .docx reader drops every image and flattens all
//  paragraph styles, and RTF loses the association between a floating image
//  and its paragraph.
//
//  Scope matches what Inkling's own editor toolbar can produce: paragraph
//  text, bold/italic, Word's Title/Heading styles, a flat bullet marker for
//  any list paragraph, and images (dropped in at their paragraph's position
//  and left to Inkling's existing auto-float, not given an explicit page
//  position). Tables, footnotes, comments, track changes, headers/footers,
//  colors, and underline are not read — those paragraphs' plain text (if any
//  reachable as ordinary runs) is skipped along with them.
//

import AppKit
import Foundation

enum WordDocumentImporter {

    enum ImportError: LocalizedError {
        case notAZipArchive
        case missingDocumentXML
        case malformedDocumentXML

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                return "The file isn't a valid Word document (.docx)."
            case .missingDocumentXML:
                return "The file is missing its document contents."
            case .malformedDocumentXML:
                return "The file's document contents could not be read."
            }
        }
    }

    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func importChapterBody(from url: URL, maximumImageWidth: CGFloat) throws -> NSAttributedString {
        let reader: MinimalZipReader
        do {
            reader = try MinimalZipReader(contentsOf: url)
        } catch {
            throw ImportError.notAZipArchive
        }

        guard let documentData = try? reader.contents(of: "word/document.xml") else {
            throw ImportError.missingDocumentXML
        }
        guard let xmlDoc = try? XMLDocument(data: documentData, options: []),
              let root = xmlDoc.rootElement(),
              let body = firstDescendant(of: root, localName: "body")
        else {
            throw ImportError.malformedDocumentXML
        }

        let relationships = (try? reader.contents(of: "word/_rels/document.xml.rels"))
            .flatMap(relationshipTargets(from:)) ?? [:]

        let result = NSMutableAttributedString()
        let paragraphs = (body.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "p" }
        for paragraph in paragraphs {
            result.append(attributedString(
                for: paragraph, reader: reader, relationships: relationships, maximumImageWidth: maximumImageWidth
            ))
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }

    // MARK: - Relationships (rId -> media file path, relative to word/)

    nonisolated private static func relationshipTargets(from relsData: Data) -> [String: String]? {
        guard let doc = try? XMLDocument(data: relsData, options: []), let root = doc.rootElement() else { return nil }
        var map: [String: String] = [:]
        for case let relationship as XMLElement in root.children ?? [] where relationship.localName == "Relationship" {
            guard let id = relationship.attribute(forName: "Id")?.stringValue,
                  let target = relationship.attribute(forName: "Target")?.stringValue
            else { continue }
            map[id] = target
        }
        return map
    }

    // MARK: - Paragraphs

    private static func attributedString(
        for paragraph: XMLElement,
        reader: MinimalZipReader,
        relationships: [String: String],
        maximumImageWidth: CGFloat
    ) -> NSAttributedString {
        let style = paragraphStyle(of: paragraph)
        let result = NSMutableAttributedString()
        if isBulletedParagraph(paragraph) {
            result.append(NSAttributedString(string: "•\t", attributes: [.font: style.font]))
        }

        let runs = (paragraph.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "r" }
        for run in runs {
            result.append(attributedString(
                for: run, baseFont: style.font, reader: reader, relationships: relationships,
                maximumImageWidth: maximumImageWidth
            ))
        }
        return result
    }

    /// Word's built-in heading styles carry fixed, non-localized style IDs
    /// (`Title`, `Heading1`, `Heading2`, …) regardless of the document's
    /// display language, so matching on the ID alone is safe.
    private static func paragraphStyle(of paragraph: XMLElement) -> TextStyle {
        guard let pPr = child(of: paragraph, localName: "pPr"),
              let pStyle = child(of: pPr, localName: "pStyle"),
              let styleId = pStyle.attribute(forLocalName: "val", uri: wordNamespace)?.stringValue
        else { return .body }

        switch styleId {
        case "Title": return .title
        case "Heading1": return .heading
        default: return styleId.hasPrefix("Heading") ? .subheading : .body
        }
    }

    /// Inkling doesn't model real lists — its own bullet button just prefixes
    /// "•\t" onto each paragraph — so any Word list paragraph (numbered or
    /// bulleted; Inkling doesn't distinguish) maps the same way.
    private static func isBulletedParagraph(_ paragraph: XMLElement) -> Bool {
        guard let pPr = child(of: paragraph, localName: "pPr") else { return false }
        return child(of: pPr, localName: "numPr") != nil
    }

    // MARK: - Runs

    private static func attributedString(
        for run: XMLElement,
        baseFont: NSFont,
        reader: MinimalZipReader,
        relationships: [String: String],
        maximumImageWidth: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = runFont(for: run, baseFont: baseFont)

        for case let node as XMLElement in run.children ?? [] {
            switch node.localName {
            case "t":
                result.append(NSAttributedString(string: node.stringValue ?? "", attributes: [.font: font]))
            case "tab":
                result.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            case "br":
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            case "drawing":
                if let attachment = attachment(
                    for: node, reader: reader, relationships: relationships, maximumImageWidth: maximumImageWidth
                ) {
                    result.append(NSAttributedString(attachment: attachment))
                }
            default:
                break
            }
        }
        return result
    }

    private static func runFont(for run: XMLElement, baseFont: NSFont) -> NSFont {
        guard let runProperties = child(of: run, localName: "rPr") else { return baseFont }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if isRunPropertyOn(runProperties, localName: "b") { traits.insert(.bold) }
        if isRunPropertyOn(runProperties, localName: "i") { traits.insert(.italic) }
        guard !traits.isEmpty else { return baseFont }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
    }

    /// OOXML boolean run properties (`<w:b/>`) default to "on" when present
    /// with no value, and are only "off" via an explicit false-ish `w:val`.
    private static func isRunPropertyOn(_ runProperties: XMLElement, localName: String) -> Bool {
        guard let element = child(of: runProperties, localName: localName) else { return false }
        guard let val = element.attribute(forLocalName: "val", uri: wordNamespace)?.stringValue else { return true }
        return !["0", "false", "off"].contains(val.lowercased())
    }

    // MARK: - Images

    /// Every image — inline or floating in Word — becomes a plain attachment
    /// dropped at this exact position in its paragraph. Inkling's own
    /// paragraph-first-line auto-float (the same behavior a freshly pasted
    /// image gets) takes it from there; no attempt is made to reproduce
    /// Word's on-page pixel position.
    private static func attachment(
        for drawing: XMLElement,
        reader: MinimalZipReader,
        relationships: [String: String],
        maximumImageWidth: CGFloat
    ) -> NSTextAttachment? {
        guard let blip = firstDescendant(of: drawing, localName: "blip"),
              let rId = blip.attribute(forLocalName: "embed", uri: relationshipsNamespace)?.stringValue,
              let target = relationships[rId],
              let imageData = try? reader.contents(of: "word/" + target),
              let image = NSImage(data: imageData)
        else { return nil }

        return RichTextImageInserter.makeAttachment(for: image, maximumWidth: maximumImageWidth)
    }

    // MARK: - XML helpers

    private static func child(of element: XMLElement, localName: String) -> XMLElement? {
        (element.children ?? []).compactMap { $0 as? XMLElement }.first { $0.localName == localName }
    }

    private static func firstDescendant(of element: XMLElement, localName: String) -> XMLElement? {
        if element.localName == localName { return element }
        for case let child as XMLElement in element.children ?? [] {
            if let found = firstDescendant(of: child, localName: localName) { return found }
        }
        return nil
    }
}
