//
//  RichTextCodec.swift
//  Inkling
//
//  One format boundary for chapter and note rich text. RTFD embeds image
//  attachments; the RTF fallback keeps every existing Inkling file readable.
//

import AppKit

enum RichTextCodec {
    private static let attachmentMetadataFilename = "__inkling_attachment_sizes.json"

    private struct AttachmentSizeRecord: Codable {
        let location: Int
        let width: Double
        let height: Double
        // Present only for images the user has positioned on a page. Optional so
        // older sidecars (sizes only) still decode, and un-moved images stay
        // free of a stored position.
        var page: Int?
        var originX: Double?
        var originY: Double?
    }

    static func decode(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }
        guard let attributed = NSAttributedString(rtfd: data, documentAttributes: nil)
            ?? NSAttributedString(rtf: data, documentAttributes: nil)
        else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        restoreAttachmentSizes(in: mutable, from: data)
        return mutable
    }

    static func encode(_ attributedString: NSAttributedString) -> Data? {
        guard let rtfd = attributedString.rtfd(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [:]
        ) else { return nil }

        let records = attachmentSizeRecords(in: attributedString)
        guard !records.isEmpty,
              let metadata = try? JSONEncoder().encode(records),
              let wrapper = FileWrapper(serializedRepresentation: rtfd)
        else { return rtfd }

        if let existing = wrapper.fileWrappers?[attachmentMetadataFilename] {
            wrapper.removeFileWrapper(existing)
        }
        wrapper.addRegularFile(
            withContents: metadata,
            preferredFilename: attachmentMetadataFilename
        )
        return wrapper.serializedRepresentation
    }

    /// RTFD embeds attachment files but does not preserve NSTextAttachment's
    /// display bounds. Store those bounds in a private sidecar inside the RTFD
    /// package without reducing the original image or migrating Core Data.
    private static func attachmentSizeRecords(
        in attributedString: NSAttributedString
    ) -> [AttachmentSizeRecord] {
        var records: [AttachmentSizeRecord] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let size = (attachment as? FloatingImageAttachment)?.displaySize
                ?? attachment.bounds.size
            guard size.width > 0, size.height > 0
            else { return }
            let position = (attachment as? FloatingImageAttachment)?.position
            records.append(AttachmentSizeRecord(
                location: range.location,
                width: size.width,
                height: size.height,
                page: position?.page,
                originX: position.map { Double($0.origin.x) },
                originY: position.map { Double($0.origin.y) }
            ))
        }
        return records
    }

    private static func restoreAttachmentSizes(
        in attributedString: NSMutableAttributedString,
        from data: Data
    ) {
        guard let wrapper = FileWrapper(serializedRepresentation: data),
              let metadata = wrapper.fileWrappers?[attachmentMetadataFilename]?.regularFileContents,
              let records = try? JSONDecoder().decode([AttachmentSizeRecord].self, from: metadata)
        else { return }

        for record in records where record.location < attributedString.length {
            guard let attachment = attributedString.attribute(
                .attachment,
                at: record.location,
                effectiveRange: nil
            ) as? NSTextAttachment else { continue }

            // Carry any stored page placement forward as an in-memory attribute
            // so the editor and printer can build a positioned attachment from it.
            if let page = record.page, let originX = record.originX, let originY = record.originY {
                attributedString.addAttribute(
                    .inklingFloatingImagePosition,
                    value: FloatingImagePosition(
                        page: page,
                        origin: CGPoint(x: originX, y: originY)
                    ),
                    range: NSRange(location: record.location, length: 1)
                )
            }

            // RTFD decoding produces a *cell-backed* attachment whose layout size
            // comes from the embedded image and ignores `bounds`. Convert it to a
            // plain image-backed attachment so our stored display size is honored.
            if attachment.image == nil {
                if let cell = attachment.attachmentCell as? NSTextAttachmentCell,
                   let cellImage = cell.image {
                    attachment.image = cellImage
                } else if let contents = attachment.fileWrapper?.regularFileContents,
                          let image = NSImage(data: contents) {
                    attachment.image = image
                }
            }
            attachment.attachmentCell = nil

            attachment.image?.size = NSSize(width: record.width, height: record.height)
            attachment.bounds = NSRect(
                x: 0,
                y: 0,
                width: record.width,
                height: record.height
            )
        }
    }
}
