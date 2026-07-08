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

enum WordDocumentExporter {

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
        guard let body = RichTextCodec.decode(chapter.bodyData) else {
            throw ExportError.unreadableBody
        }

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
        var properties = ""
        if let style = paragraphStyle(in: attributed, range: range) {
            properties = #"<w:pPr><w:pStyle w:val="\#(style)"/></w:pPr>"#
        }

        var runs = ""
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment,
               let image = pngData(from: attachment) {
                let name = "image\(state.imageIndex).png"
                state.media.append((name, image.data))
                runs += imageRunXML(
                    relationshipID: "rId\(state.imageIndex)",
                    docPrID: state.imageIndex,
                    pixelSize: image.pixelSize
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

    /// EMU (English Metric Units) per pixel at the 96 DPI Word assumes for inline drawings.
    private static let emuPerPixel = 9525

    private static func imageRunXML(relationshipID: String, docPrID: Int, pixelSize: CGSize) -> String {
        let cx = max(1, Int(pixelSize.width)) * emuPerPixel
        let cy = max(1, Int(pixelSize.height)) * emuPerPixel
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(docPrID)" name="Picture \(docPrID)"/>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(docPrID)" name="Picture \(docPrID)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private static func pngData(from attachment: NSTextAttachment) -> (data: Data, pixelSize: CGSize)? {
        let image = attachment.image
            ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image
            ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        return (data, pixelSize)
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
    private static let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
        <w:rPr><w:b/><w:sz w:val="56"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:rPr><w:b/><w:sz w:val="44"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
        <w:rPr><w:b/><w:sz w:val="34"/></w:rPr></w:style>\
        </w:styles>
        """

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

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xedb8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }
}
