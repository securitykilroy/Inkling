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
    ///
    /// Half a line: body text is 14pt, so a line box is ~17pt. Paragraphs are
    /// marked by this gap alone — there is deliberately no first-line indent,
    /// and adding one would be redundant. This started at 6pt, which is only a
    /// third of a line: too small to read unambiguously as a break, and dense
    /// pages of long paragraphs ran together as a result.
    nonisolated static let defaultParagraphSpacing: CGFloat = 9

    /// First-line indent for body paragraphs. Deliberately smaller than the
    /// ~1em a book would use if the indent were the *only* paragraph marker:
    /// the gap above already does that job, so this is texture on the left
    /// edge rather than a signal, and a full-size indent alongside a gap reads
    /// as a mistake. Headings stay flush — see `applyDefaultParagraphStyling`.
    nonisolated static let defaultFirstLineIndent: CGFloat = 12

    nonisolated static var defaultParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = defaultParagraphSpacing
        style.firstLineHeadIndent = defaultFirstLineIndent
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
        var importedPlacementHint: ImportedImagePlacementHint?
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
        applyDefaultParagraphStyling(in: mutable)
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

    /// Backfills the default paragraph spacing and body first-line indent onto
    /// any paragraph missing them, preserving any other paragraph-style
    /// properties (alignment, etc.) already present. Safe to run on every
    /// decode: whatever a paragraph already carries is left untouched.
    ///
    /// The two properties are checked **independently**. Chapters saved before
    /// the indent existed already carry non-zero spacing, so a combined test
    /// would skip them and the indent would only ever reach newly typed text.
    ///
    /// Headings keep a flush left edge — an indented Title/Heading reads as a
    /// mistake — using the same bold-and-≥17pt test the sidebar outline uses.
    /// Callout styling runs after this and sets its own indents, so callouts
    /// are unaffected.
    nonisolated private static func applyDefaultParagraphStyling(in attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        let string = attributedString.string as NSString

        var location = 0
        while location < attributedString.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }

            let existing = attributedString.attribute(
                .paragraphStyle, at: paragraph.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let updated = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            var changed = false

            if (existing?.paragraphSpacing ?? 0) == 0 {
                updated.paragraphSpacing = defaultParagraphSpacing
                changed = true
            }
            if (existing?.firstLineHeadIndent ?? 0) == 0,
               !isHeadingParagraph(paragraph, in: attributedString) {
                updated.firstLineHeadIndent = defaultFirstLineIndent
                changed = true
            }
            if changed {
                attributedString.addAttribute(.paragraphStyle, value: updated, range: paragraph)
            }
            location = paragraph.location + paragraph.length
        }
    }

    /// The same bold-and-large test `ChapterOutline` uses to spot headings.
    nonisolated private static func isHeadingParagraph(
        _ range: NSRange,
        in attributedString: NSAttributedString
    ) -> Bool {
        guard let font = attributedString.attribute(
            .font, at: range.location, effectiveRange: nil
        ) as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold) && font.pointSize >= 17
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
            let importedPlacementHint = (attachment as? FloatingImageAttachment)?.importedPlacementHint
                ?? attributedString.attribute(
                    .inklingImportedImagePlacementHint,
                    at: range.location,
                    effectiveRange: nil
                ) as? ImportedImagePlacementHint
            records.append(AttachmentSizeRecord(
                location: range.location,
                width: size.width,
                height: size.height,
                page: position?.page,
                originX: position.map { Double($0.origin.x) },
                originY: position.map { Double($0.origin.y) },
                importedPlacementHint: position == nil ? importedPlacementHint : nil
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
            } else if let hint = record.importedPlacementHint {
                attributedString.addAttribute(
                    .inklingImportedImagePlacementHint,
                    value: hint,
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
