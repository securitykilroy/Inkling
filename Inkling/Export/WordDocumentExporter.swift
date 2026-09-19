//
//  WordDocumentExporter.swift
//  Inkling
//
//  Writes one chapter body to a small .docx package. Scope intentionally
//  mirrors WordDocumentImporter and the editor toolbar: paragraphs, the four
//  Inkling text styles, bold/italic runs, tabs, line breaks, and images.
//

import AppKit
import Foundation

private extension NSAttributedString.Key {
    /// Export-only tag marking paragraphs that came from an expanded floating
    /// sidebar, so they get the bordered Word "Sidebar" style + label.
    nonisolated static let inklingWordSidebar = NSAttributedString.Key("inklingWordSidebar")
    /// Temporary export-only identity used while moving a floating image's Word
    /// anchor to the page where Inkling displays it.
    nonisolated static let inklingWordAnchorID = NSAttributedString.Key("inklingWordAnchorID")
}

enum WordDocumentExporter {

    static let sidebarWordStyleID = "SidebarBox"

    private final class ExportState {
        var imageIndex = 1
        var media: [(name: String, data: Data)] = []
    }

    enum ExportError: LocalizedError {
        case unreadableBody
        case noChapters

        var errorDescription: String? {
            switch self {
            case .unreadableBody:
                return "The chapter body could not be converted to Word format."
            case .noChapters:
                return "There are no chapters to export."
            }
        }
    }

    static func docxData(for chapter: PrintableChapter) throws -> Data {
        let decoded: NSAttributedString
        do {
            decoded = try chapter.decodedBody()
        } catch {
            throw ExportError.unreadableBody
        }
        let body = expandSidebars(relocatingPositionedImageAnchors(decoded))

        let state = ExportState()
        let bodyXML = documentBodyXML(from: body, state: state)
        let relationships = relationshipsXML(forImageCount: state.media.count)
        let contentTypes = contentTypesXML(hasImages: !state.media.isEmpty)
        let document = documentXML(bodyXML: bodyXML)

        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(packageRelationshipsXML.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(relationships.utf8)),
            ("word/styles.xml", Data(stylesXML.utf8)),
        ]
        entries.append(contentsOf: state.media.map { ("word/media/\($0.name)", $0.data) })
        return ZipArchiveWriter.makeZip(entries: entries)
    }

    static func exportChapters(_ chapters: [PrintableChapter], to folder: URL) throws -> [URL] {
        let exportable = chapters.filter(\.hasContent)
        guard !exportable.isEmpty else { throw ExportError.noChapters }

        var written: [URL] = []
        for (index, chapter) in exportable.enumerated() {
            let baseName = sanitizedFilename(chapter.title, fallback: "Chapter \(index + 1)")
            let url = uniqueURL(in: folder, baseName: baseName, extension: "docx")
            try docxData(for: chapter).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    private static func documentBodyXML(
        from attributed: NSAttributedString,
        state: ExportState
    ) -> String {
        var paragraphs: [String] = []
        let nsString = attributed.string as NSString
        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: attributed.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, paragraphRange, _, _ in
            paragraphs.append(paragraphXML(
                from: attributed,
                range: paragraphRange,
                state: state
            ))
        }
        if paragraphs.isEmpty {
            paragraphs.append("<w:p/>")
        }
        return paragraphs.joined()
    }

    private static func paragraphXML(
        from attributed: NSAttributedString,
        range: NSRange,
        state: ExportState
    ) -> String {
        // A sidebar or callout paragraph gets its bordered/shaded style; otherwise
        // fall back to the heading-style mapping. All three are mutually exclusive.
        let isSidebar = attributeIsPresent(.inklingWordSidebar, in: attributed, at: range.location)
        let callout = isSidebar ? nil : calloutKind(in: attributed, at: range.location)
        var properties = ""
        if isSidebar {
            properties = #"<w:pPr><w:pStyle w:val="\#(sidebarWordStyleID)"/></w:pPr>"#
        } else if let callout {
            properties = #"<w:pPr><w:pStyle w:val="\#(wordStyleID(for: callout))"/></w:pPr>"#
        } else if let style = paragraphStyle(in: attributed, range: range) {
            properties = #"<w:pPr><w:pStyle w:val="\#(style)"/></w:pPr>"#
        }

        // The label leads the first paragraph of a sidebar/callout as a bold run,
        // so the aside is clearly labeled and its text is fully extractable in Word.
        var runs = ""
        if isSidebar, !attributeIsPresent(.inklingWordSidebar, in: attributed, at: range.location - 1) {
            let label = attributed.attribute(
                .inklingWordSidebar, at: range.location, effectiveRange: nil
            ) as? String ?? SidebarStyle.defaultTitle
            runs += #"<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">\#(escapeXML(label)) — </w:t></w:r>"#
        } else if let callout, isFirstCalloutParagraph(in: attributed, at: range.location, kind: callout) {
            runs += #"<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">\#(callout.exportLabel) — </w:t></w:r>"#
        }
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment,
               let image = pngData(from: attachment) {
                let name = "image\(state.imageIndex).png"
                state.media.append((name, image.data))
                runs += imageRunXML(
                    relationshipID: "rId\(state.imageIndex)",
                    docPrID: state.imageIndex,
                    displaySize: image.displaySize,
                    position: (attachment as? FloatingImageAttachment)?.position
                        ?? attributes[.inklingFloatingImagePosition] as? FloatingImagePosition,
                    importedPlacementHint: (attachment as? FloatingImageAttachment)?.importedPlacementHint
                        ?? attributes[.inklingImportedImagePlacementHint] as? ImportedImagePlacementHint
                )
                state.imageIndex += 1
                return
            }

            let text = nsString(attributed).substring(with: runRange)
            guard !text.isEmpty else { return }
            runs += textRunXML(text, font: attributes[.font] as? NSFont)
        }
        return "<w:p>\(properties)\(runs)</w:p>"
    }

    /// Replaces each floating sidebar anchor with its content as real paragraphs,
    /// tagged for the bordered Word "Sidebar" style, inline where it was anchored.
    private static func expandSidebars(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        var anchors: [(range: NSRange, replacement: NSAttributedString)] = []
        mutable.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: mutable.length)
        ) { value, range, _ in
            guard let sidebar = value as? SidebarAttachment else { return }
            let content = NSMutableAttributedString(
                attributedString: RichTextCodec.decode(sidebar.contentData) ?? NSAttributedString(string: "")
            )
            if content.length == 0 { content.append(NSAttributedString(string: " ")) }
            if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n")) }
            // The attribute's *value* is the box's title, so the label run
            // below can name the aside without re-finding its anchor. Presence
            // is still what marks the paragraphs as sidebar text.
            content.addAttribute(
                .inklingWordSidebar,
                value: sidebar.displayTitle,
                range: NSRange(location: 0, length: content.length)
            )

            let replacement = NSMutableAttributedString(string: "\n")
            replacement.append(content)
            anchors.append((range, replacement))
        }
        for anchor in anchors.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: anchor.range, with: anchor.replacement)
        }
        return mutable
    }

    /// Word positions a floating drawing relative to the page containing its
    /// text anchor; OOXML has no independent page-number field. Inkling does — a
    /// user can drag an image to another page without moving its invisible text
    /// anchor. Move only the export snapshot's anchor well inside the saved
    /// page so Word has the same page association, leaving the real chapter and
    /// the image's page-local x/y untouched.
    private static func relocatingPositionedImageAnchors(
        _ attributed: NSAttributedString
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        var anchors: [(id: String, page: Int)] = []
        mutable.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: mutable.length)
        ) { value, range, _ in
            guard value is NSTextAttachment,
                  !(value is SidebarAttachment),
                  let position = (value as? FloatingImageAttachment)?.position
                    ?? mutable.attribute(
                        .inklingFloatingImagePosition,
                        at: range.location,
                        effectiveRange: nil
                    ) as? FloatingImagePosition
            else { return }
            let id = UUID().uuidString
            mutable.addAttribute(.inklingWordAnchorID, value: id, range: range)
            anchors.append((id, position.page))
        }

        // Moving one anchor repaginates everything after it, so the next anchor
        // has to be measured against the updated text — but only *moving* an
        // anchor invalidates the layout. Most images are already on the page
        // they belong to, so laying the chapter out lazily and only after a
        // real move turns the common case from one full pagination per image
        // into one for the whole chapter.
        var cachedStack: PageStackView?
        for anchor in anchors {
            let stack = cachedStack ?? Self.laidOutStack(for: mutable)
            cachedStack = stack
            guard anchor.page >= 0, anchor.page < stack.pageCount else { continue }

            var source = NSRange(location: NSNotFound, length: 0)
            stack.storage.enumerateAttribute(
                .inklingWordAnchorID,
                in: NSRange(location: 0, length: stack.storage.length)
            ) { value, range, stop in
                if value as? String == anchor.id {
                    source = range
                    stop.pointee = true
                }
            }
            guard source.location != NSNotFound else { continue }
            let targetPage = stack.characterRange(ofPage: anchor.page)
            if targetPage.length > 0, NSLocationInRange(source.location, targetPage) { continue }

            // Use a paragraph comfortably inside the page, not its first
            // character. Word and TextKit can differ by a line at a page
            // boundary after style conversion; anchoring at that knife edge
            // can therefore put the drawing back on the preceding Word page.
            let midpoint = targetPage.location + targetPage.length / 2
            var destination = (mutable.string as NSString).paragraphRange(
                for: NSRange(location: min(midpoint, mutable.length), length: 0)
            ).location
            let token = mutable.attributedSubstring(from: source)
            mutable.deleteCharacters(in: source)
            if source.location < destination { destination -= source.length }
            destination = min(max(0, destination), mutable.length)
            mutable.insert(token, at: destination)
            // `mutable` has moved on; the next anchor needs a fresh layout.
            cachedStack = nil
        }

        mutable.removeAttribute(
            .inklingWordAnchorID,
            range: NSRange(location: 0, length: mutable.length)
        )
        return mutable
    }

    /// A page stack holding `text`, paginated and with its floating images and
    /// sidebars placed — the same layout the editor shows, which is what makes
    /// the exported anchor land on the page the author sees.
    private static func laidOutStack(for text: NSAttributedString) -> PageStackView {
        let stack = PageStackView()
        stack.setAttributedString(text)
        stack.prepareFloatingImages()
        stack.prepareSidebars()
        return stack
    }

    private static func attributeIsPresent(_ key: NSAttributedString.Key, in attributed: NSAttributedString, at location: Int) -> Bool {
        guard location >= 0, location < attributed.length else { return false }
        return attributed.attribute(key, at: location, effectiveRange: nil) != nil
    }

    /// The callout kind covering the paragraph starting at `location`, if any.
    private static func calloutKind(in attributed: NSAttributedString, at location: Int) -> CalloutKind? {
        guard location < attributed.length else { return nil }
        let raw = attributed.attribute(.inklingCallout, at: location, effectiveRange: nil) as? String
        return raw.flatMap(CalloutKind.init(storedRawValue:))
    }

    /// Whether the paragraph at `location` opens its callout (nothing before it,
    /// or the preceding character belongs to a different/absent callout), so only
    /// the first paragraph of a callout carries the label run.
    private static func isFirstCalloutParagraph(
        in attributed: NSAttributedString,
        at location: Int,
        kind: CalloutKind
    ) -> Bool {
        guard location > 0 else { return true }
        return calloutKind(in: attributed, at: location - 1) != kind
    }

    nonisolated private static func wordStyleID(for kind: CalloutKind) -> String {
        "\(kind.rawValue.capitalized)Callout"
    }

    private static func paragraphStyle(in attributed: NSAttributedString, range: NSRange) -> String? {
        guard range.length > 0 else { return nil }
        var font: NSFont?
        attributed.enumerateAttribute(.font, in: range) { value, _, stop in
            if let value = value as? NSFont {
                font = value
                stop.pointee = true
            }
        }
        guard let font else { return nil }
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        if bold && font.pointSize >= 27 { return "Title" }
        if bold && font.pointSize >= 21 { return "Heading1" }
        if bold && font.pointSize >= 16 { return "Heading2" }
        return nil
    }

    private static func textRunXML(_ text: String, font: NSFont?) -> String {
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        var properties = ""
        if let family = font?.familyName, !family.hasPrefix(".") {
            let escapedFamily = escapeXML(family)
            properties += #"<w:rFonts w:ascii="\#(escapedFamily)" w:hAnsi="\#(escapedFamily)"/>"#
        }
        if let font {
            let halfPoints = max(1, Int((font.pointSize * 2).rounded()))
            properties += #"<w:sz w:val="\#(halfPoints)"/><w:szCs w:val="\#(halfPoints)"/>"#
        }
        if traits.contains(.bold) { properties += "<w:b/>" }
        if traits.contains(.italic) { properties += "<w:i/>" }
        let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"

        var content = ""
        var buffer = String.UnicodeScalarView()
        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            content += #"<w:t xml:space="preserve">\#(escapeXML(String(buffer)))</w:t>"#
            buffer.removeAll()
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t":
                flushBuffer()
                content += "<w:tab/>"
            case "\n", "\r":
                flushBuffer()
                content += "<w:br/>"
            default:
                buffer.append(scalar)
            }
        }
        flushBuffer()
        return "<w:r>\(runProperties)\(content)</w:r>"
    }

    private static let emuPerPoint = 12_700.0

    private static func imageRunXML(
        relationshipID: String,
        docPrID: Int,
        displaySize: CGSize,
        position: FloatingImagePosition?,
        importedPlacementHint: ImportedImagePlacementHint?
    ) -> String {
        let cx = max(1, Int((displaySize.width * emuPerPoint).rounded()))
        let cy = max(1, Int((displaySize.height * emuPerPoint).rounded()))
        let drawingStart: String
        let drawingEnd: String
        if let position {
            let x = Int((position.origin.x * emuPerPoint).rounded())
            let y = Int((position.origin.y * emuPerPoint).rounded())
            drawingStart = """
            <wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">\
            <wp:simplePos x="0" y="0"/>\
            <wp:positionH relativeFrom="page"><wp:posOffset>\(x)</wp:posOffset></wp:positionH>\
            <wp:positionV relativeFrom="page"><wp:posOffset>\(y)</wp:posOffset></wp:positionV>
            """
            drawingEnd = "</wp:anchor>"
        } else if let hint = importedPlacementHint {
            drawingStart = """
            <wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">\
            <wp:simplePos x="0" y="0"/>\
            \(positionXML(axis: "H", reference: hint.horizontalReference, alignment: hint.horizontalAlignment, offset: hint.horizontalOffset))\
            \(positionXML(axis: "V", reference: hint.verticalReference, alignment: hint.verticalAlignment, offset: hint.verticalOffset))
            """
            drawingEnd = "</wp:anchor>"
        } else {
            drawingStart = #"<wp:inline distT="0" distB="0" distL="0" distR="0">"#
            drawingEnd = "</wp:inline>"
        }
        let wrap = position == nil && importedPlacementHint == nil
            ? ""
            : #"<wp:wrapSquare wrapText="bothSides"/>"#
        return """
        <w:r><w:drawing>\(drawingStart)\
        <wp:extent cx="\(cx)" cy="\(cy)"/>\
        \(wrap)\
        <wp:docPr id="\(docPrID)" name="Picture \(docPrID)"/>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(docPrID)" name="Picture \(docPrID)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic>\(drawingEnd)</w:drawing></w:r>
        """
    }

    private static func positionXML(
        axis: String,
        reference: ImportedImageReference,
        alignment: ImportedImageAlignment?,
        offset: Double?
    ) -> String {
        let relativeFrom: String
        switch reference {
        case .page: relativeFrom = "page"
        case .margin: relativeFrom = "margin"
        case .column: relativeFrom = axis == "H" ? "column" : "margin"
        case .character: relativeFrom = axis == "H" ? "character" : "paragraph"
        case .paragraph: relativeFrom = axis == "V" ? "paragraph" : "column"
        case .line: relativeFrom = axis == "V" ? "line" : "column"
        }
        let value: String
        if let offset {
            value = "<wp:posOffset>\(Int((offset * emuPerPoint).rounded()))</wp:posOffset>"
        } else {
            let wordAlignment: String
            switch alignment {
            case .center: wordAlignment = "center"
            case .end: wordAlignment = axis == "H" ? "right" : "bottom"
            case .start, nil: wordAlignment = axis == "H" ? "left" : "top"
            }
            value = "<wp:align>\(wordAlignment)</wp:align>"
        }
        return "<wp:position\(axis) relativeFrom=\"\(relativeFrom)\">\(value)</wp:position\(axis)>"
    }

    private static func pngData(from attachment: NSTextAttachment) -> (data: Data, displaySize: CGSize)? {
        let image = attachment.image
            ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image
            ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        let displaySize: CGSize
        if let floating = attachment as? FloatingImageAttachment,
           floating.displaySize.width > 0,
           floating.displaySize.height > 0 {
            displaySize = floating.displaySize
        } else if attachment.bounds.width > 0, attachment.bounds.height > 0 {
            displaySize = attachment.bounds.size
        } else {
            displaySize = image.size
        }
        return (data, displaySize)
    }

    private static func documentXML(bodyXML: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(bodyXML)\
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" \
        w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
        """
    }

    private static let packageRelationshipsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """

    private static func relationshipsXML(forImageCount count: Int) -> String {
        let images = count == 0 ? "" : (1...count).map {
            #"<Relationship Id="rId\#($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\#($0).png"/>"#
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        \(images)</Relationships>
        """
    }

    private static func contentTypesXML(hasImages: Bool) -> String {
        let pngDefault = hasImages ? #"<Default Extension="png" ContentType="image/png"/>"# : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(pngDefault)\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        </Types>
        """
    }

    /// Point sizes mirror `TextStyle` in RichTextController; OOXML `w:sz` is in half-points.
    private static var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
        <w:rPr><w:b/><w:sz w:val="56"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:rPr><w:b/><w:sz w:val="44"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
        <w:rPr><w:b/><w:sz w:val="34"/></w:rPr></w:style>\
        \(CalloutKind.allCases.map(calloutStyleXML).joined())\
        \(sidebarStyleXML)\
        </w:styles>
        """
    }

    /// A shaded, bordered paragraph style for expanded floating sidebars, using
    /// the same colors as the on-screen/printed box.
    private static var sidebarStyleXML: String {
        let border = ["top", "left", "bottom", "right"].map {
            #"<w:\#($0) w:val="single" w:sz="12" w:space="6" w:color="\#(SidebarStyle.accentHex)"/>"#
        }.joined()
        return """
        <w:style w:type="paragraph" w:styleId="\(sidebarWordStyleID)"><w:name w:val="\(sidebarWordStyleID)"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:pBdr>\(border)</w:pBdr>\
        <w:shd w:val="clear" w:color="auto" w:fill="\(SidebarStyle.fillHex)"/>\
        <w:ind w:left="240" w:right="240"/><w:spacing w:before="120" w:after="120"/></w:pPr></w:style>
        """
    }

    /// A shaded, four-sided-bordered paragraph style for a callout kind. Adjacent
    /// paragraphs sharing this style merge into one visual box in Word. Colors
    /// come from the same hex values the on-screen/printed box uses.
    nonisolated private static func calloutStyleXML(for kind: CalloutKind) -> String {
        let id = wordStyleID(for: kind)
        let border = ["top", "left", "bottom", "right"].map {
            #"<w:\#($0) w:val="single" w:sz="12" w:space="6" w:color="\#(kind.accentHex)"/>"#
        }.joined()
        return """
        <w:style w:type="paragraph" w:styleId="\(id)"><w:name w:val="\(id)"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:pBdr>\(border)</w:pBdr>\
        <w:shd w:val="clear" w:color="auto" w:fill="\(kind.fillHex)"/>\
        <w:ind w:left="240" w:right="240"/><w:spacing w:before="120" w:after="120"/></w:pPr></w:style>
        """
    }

    private static func nsString(_ attributed: NSAttributedString) -> NSString {
        attributed.string as NSString
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sanitizedFilename(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let clean = source
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }

    private static func uniqueURL(in folder: URL, baseName: String, extension pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }
}

private enum ZipArchiveWriter {
    static func makeZip(entries: [(name: String, data: Data)]) -> Data {
        var result = Data()
        var centralDirectory = Data()

        for entry in entries {
            let localOffset = result.count
            let nameData = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)

            result.append(contentsOf: uint32LE(0x0403_4b50))
            result.append(contentsOf: uint16LE(20))
            result.append(contentsOf: uint16LE(0))
            result.append(contentsOf: uint16LE(0))
            result.append(contentsOf: uint16LE(0))
            result.append(contentsOf: uint16LE(0))
            result.append(contentsOf: uint32LE(crc))
            result.append(contentsOf: uint32LE(UInt32(entry.data.count)))
            result.append(contentsOf: uint32LE(UInt32(entry.data.count)))
            result.append(contentsOf: uint16LE(UInt16(nameData.count)))
            result.append(contentsOf: uint16LE(0))
            result.append(nameData)
            result.append(entry.data)

            centralDirectory.append(contentsOf: uint32LE(0x0201_4b50))
            centralDirectory.append(contentsOf: uint16LE(20))
            centralDirectory.append(contentsOf: uint16LE(20))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint32LE(crc))
            centralDirectory.append(contentsOf: uint32LE(UInt32(entry.data.count)))
            centralDirectory.append(contentsOf: uint32LE(UInt32(entry.data.count)))
            centralDirectory.append(contentsOf: uint16LE(UInt16(nameData.count)))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint16LE(0))
            centralDirectory.append(contentsOf: uint32LE(0))
            centralDirectory.append(contentsOf: uint32LE(UInt32(localOffset)))
            centralDirectory.append(nameData)
        }

        let centralOffset = result.count
        result.append(centralDirectory)
        result.append(contentsOf: uint32LE(0x0605_4b50))
        result.append(contentsOf: uint16LE(0))
        result.append(contentsOf: uint16LE(0))
        result.append(contentsOf: uint16LE(UInt16(entries.count)))
        result.append(contentsOf: uint16LE(UInt16(entries.count)))
        result.append(contentsOf: uint32LE(UInt32(centralDirectory.count)))
        result.append(contentsOf: uint32LE(UInt32(centralOffset)))
        result.append(contentsOf: uint16LE(0))
        return result
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ]
    }
}
