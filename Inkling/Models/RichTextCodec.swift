//
//  RichTextCodec.swift
//  Inkling
//
//  One format boundary for chapter and note rich text. RTFD embeds image
//  attachments; the RTF fallback keeps every existing Inkling file readable.
//

import AppKit

enum RichTextCodec {
    nonisolated private static let attachmentMetadataFilename = "__inkling_attachment_sizes.json"
    nonisolated private static let calloutMetadataFilename = "__inkling_callouts.json"
    nonisolated private static let sidebarMetadataFilename = "__inkling_sidebars.json"

    /// Space after a paragraph, in points, so a plain "\n" between paragraphs
    /// reads as a paragraph break rather than a line break. Applied to newly
    /// typed text (via typing attributes) and backfilled on decode for
    /// chapters written before this existed, including Word imports.
    nonisolated static let defaultParagraphSpacing: CGFloat = 6

    nonisolated static var defaultParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = defaultParagraphSpacing
        return style
    }

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

    /// A callout run: the paragraph range it covers and its kind. RTF can't
    /// carry the `.inklingCallout` attribute, so it rides in the sidecar and is
    /// re-applied (with its canonical styling) on decode.
    private struct CalloutRecord: Codable {
        let location: Int
        let length: Int
        let kind: String
    }

    /// A floating margin sidebar: its anchor location, box geometry, and content
    /// (RTF). The anchor character survives in the RTFD stream (the attachment
    /// carries a file wrapper); this record restores it to a full `SidebarAttachment`.
    private struct SidebarRecord: Codable {
        let location: Int
        let width: Double
        let contentHeight: Double
        var page: Int?
        var originX: Double?
        var originY: Double?
        var content: Data?
    }

    nonisolated static func decode(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }
        guard let attributed = NSAttributedString(rtfd: data, documentAttributes: nil)
            ?? NSAttributedString(rtf: data, documentAttributes: nil)
        else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        restoreAttachmentSizes(in: mutable, from: data)
        applyDefaultParagraphSpacing(in: mutable)
        restoreCallouts(in: mutable, from: data)
        restoreSidebars(in: mutable, from: data)
        return mutable
    }

    /// Rebuilds a full `SidebarAttachment` (content + placement + width) at each
    /// recorded anchor. The generic attachment produced by RTFD decoding is
    /// replaced in place, carrying over the surrounding run's attributes.
    nonisolated private static func restoreSidebars(
        in attributedString: NSMutableAttributedString,
        from data: Data
    ) {
        guard let wrapper = FileWrapper(serializedRepresentation: data),
              let metadata = wrapper.fileWrappers?[sidebarMetadataFilename]?.regularFileContents,
              let records = try? JSONDecoder().decode([SidebarRecord].self, from: metadata)
        else { return }

        for record in records where record.location < attributedString.length {
            guard attributedString.attribute(.attachment, at: record.location, effectiveRange: nil) is NSTextAttachment
            else { continue }
            var position: FloatingImagePosition?
            if let page = record.page, let x = record.originX, let y = record.originY {
                position = FloatingImagePosition(page: page, origin: CGPoint(x: x, y: y))
            }
            let sidebar = SidebarAttachment(
                contentData: record.content,
                width: CGFloat(record.width),
                position: position,
                contentHeight: CGFloat(record.contentHeight)
            )
            attributedString.addAttribute(
                .attachment,
                value: sidebar,
                range: NSRange(location: record.location, length: 1)
            )
        }
    }

    /// Re-tags callout runs recorded in the sidecar and re-applies each kind's
    /// canonical styling. Runs after `applyDefaultParagraphSpacing` so callout
    /// paragraphs get their reserved box padding rather than the default spacing.
    nonisolated private static func restoreCallouts(
        in attributedString: NSMutableAttributedString,
        from data: Data
    ) {
        guard let wrapper = FileWrapper(serializedRepresentation: data),
              let metadata = wrapper.fileWrappers?[calloutMetadataFilename]?.regularFileContents,
              let records = try? JSONDecoder().decode([CalloutRecord].self, from: metadata)
        else { return }

        for record in records {
            guard let kind = CalloutKind(storedRawValue: record.kind),
                  record.location >= 0,
                  record.location < attributedString.length
            else { continue }
            let length = min(record.length, attributedString.length - record.location)
            guard length > 0 else { continue }
            CalloutStyling.apply(kind, to: attributedString, range: NSRange(location: record.location, length: length))
        }
    }

    /// Backfills the default paragraph spacing onto any paragraph that
    /// doesn't already carry non-zero spacing, preserving any other
    /// paragraph-style properties (alignment, etc.) already present. Safe to
    /// run on every decode: a paragraph that already has spacing (from a
    /// prior save, once this exists) is left untouched.
    nonisolated private static func applyDefaultParagraphSpacing(in attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let existing = value as? NSParagraphStyle
            guard (existing?.paragraphSpacing ?? 0) == 0 else { return }
            let updated = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            updated.paragraphSpacing = defaultParagraphSpacing
            attributedString.addAttribute(.paragraphStyle, value: updated, range: range)
        }
    }

    nonisolated static func encode(_ attributedString: NSAttributedString) -> Data? {
        guard let rtfd = attributedString.rtfd(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [:]
        ) else { return nil }

        let sizeRecords = attachmentSizeRecords(in: attributedString)
        let calloutRecords = calloutRecords(in: attributedString)
        let sidebarRecords = sidebarRecords(in: attributedString)
        guard !sizeRecords.isEmpty || !calloutRecords.isEmpty || !sidebarRecords.isEmpty,
              let wrapper = FileWrapper(serializedRepresentation: rtfd)
        else { return rtfd }

        if !sizeRecords.isEmpty, let metadata = try? JSONEncoder().encode(sizeRecords) {
            replaceFile(named: attachmentMetadataFilename, contents: metadata, in: wrapper)
        }
        if !calloutRecords.isEmpty, let metadata = try? JSONEncoder().encode(calloutRecords) {
            replaceFile(named: calloutMetadataFilename, contents: metadata, in: wrapper)
        }
        if !sidebarRecords.isEmpty, let metadata = try? JSONEncoder().encode(sidebarRecords) {
            replaceFile(named: sidebarMetadataFilename, contents: metadata, in: wrapper)
        }
        return wrapper.serializedRepresentation
    }

    /// One record per floating sidebar, capturing its anchor, geometry, and RTF.
    nonisolated private static func sidebarRecords(in attributedString: NSAttributedString) -> [SidebarRecord] {
        var records: [SidebarRecord] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let sidebar = value as? SidebarAttachment else { return }
            records.append(SidebarRecord(
                location: range.location,
                width: Double(sidebar.width),
                contentHeight: Double(sidebar.contentHeight),
                page: sidebar.position?.page,
                originX: sidebar.position.map { Double($0.origin.x) },
                originY: sidebar.position.map { Double($0.origin.y) },
                content: sidebar.contentData
            ))
        }
        return records
    }

    nonisolated private static func replaceFile(named name: String, contents: Data, in wrapper: FileWrapper) {
        if let existing = wrapper.fileWrappers?[name] {
            wrapper.removeFileWrapper(existing)
        }
        wrapper.addRegularFile(withContents: contents, preferredFilename: name)
    }

    /// One record per maximal callout run. `enumerateAttribute` already coalesces
    /// adjacent equal string values, so each callback is one contiguous callout.
    nonisolated private static func calloutRecords(in attributedString: NSAttributedString) -> [CalloutRecord] {
        var records: [CalloutRecord] = []
        attributedString.enumerateAttribute(
            .inklingCallout,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let kind = value as? String, CalloutKind(storedRawValue: kind) != nil else { return }
            records.append(CalloutRecord(location: range.location, length: range.length, kind: kind))
        }
        return records
    }

    /// RTFD embeds attachment files but does not preserve NSTextAttachment's
    /// display bounds. Store those bounds in a private sidecar inside the RTFD
    /// package without reducing the original image or migrating Core Data.
    nonisolated private static func attachmentSizeRecords(
        in attributedString: NSAttributedString
    ) -> [AttachmentSizeRecord] {
        var records: [AttachmentSizeRecord] = []
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  !(attachment is SidebarAttachment) else { return }
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

    nonisolated private static func restoreAttachmentSizes(
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
                let cellImage = (attachment.attachmentCell as? NSTextAttachmentCell).flatMap { cell in
                    Thread.isMainThread ? MainActor.assumeIsolated { cell.image } : nil
                }
                if let cellImage {
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
