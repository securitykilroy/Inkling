//
//  ProjectFontStyler.swift
//  Inkling
//
//  Rewrites the typeface used across a project's rich text when the user
//  changes the project-wide font. Pure and Core-Data-free (like
//  `ProjectSearch`) so it's testable without a managed object context; the
//  caller reads `Chapter.bodyData`/`notesData` into `FontStyledChapter` and
//  writes the results back.
//

import AppKit

/// The chapter data font restyling needs — decoupled from the Core Data
/// `Chapter` type so this logic can run against plain values.
struct FontStyledChapter {
    let id: UUID
    let bodyData: Data?
    let notesData: Data?
}

enum ProjectFontStyler {
    /// Rewrites every font run in `attributed` to `familyName` (nil = system
    /// default), preserving each run's point size and bold/italic traits.
    nonisolated static func restyled(_ attributed: NSAttributedString, familyName: String?) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            mutable.addAttribute(.font, value: font.withFamily(familyName), range: range)
        }
        return mutable
    }

    /// Restyles every chapter's body and notes to `familyName`, returning the
    /// new data only for chapters that actually decoded (chapters with no
    /// rich text to restyle are omitted) — the caller writes these back onto
    /// the real `Chapter.bodyData`/`notesData`.
    nonisolated static func restyledChapters(
        _ chapters: [FontStyledChapter],
        familyName: String?
    ) -> [UUID: (bodyData: Data?, notesData: Data?)] {
        var results: [UUID: (bodyData: Data?, notesData: Data?)] = [:]
        for chapter in chapters {
            let newBody = chapter.bodyData
                .flatMap(RichTextCodec.decode)
                .flatMap { RichTextCodec.encode(restyled($0, familyName: familyName)) }
            let newNotes = chapter.notesData
                .flatMap(RichTextCodec.decode)
                .flatMap { RichTextCodec.encode(restyled($0, familyName: familyName)) }
            guard newBody != nil || newNotes != nil else { continue }
            results[chapter.id] = (bodyData: newBody ?? chapter.bodyData, notesData: newNotes ?? chapter.notesData)
        }
        return results
    }
}
