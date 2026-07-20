//
//  RichTextController.swift
//  Inkling
//
//  Bridges formatting commands from the SwiftUI toolbar to the AppKit
//  NSTextView that actually renders/edits the rich text. The editor view
//  hands its NSTextView to this controller; the toolbar calls the methods.
//

import AppKit
import Combine
import UniformTypeIdentifiers

/// Paragraph-level text styles offered in the editor's Style menu.
enum TextStyle: String, CaseIterable, Identifiable {
    case title, heading, subheading, body

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .heading: return "Heading"
        case .subheading: return "Subheading"
        case .body: return "Body"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .title: return 28
        case .heading: return 22
        case .subheading: return 17
        case .body: return 14
        }
    }

    var isBold: Bool { self != .body }

    var font: NSFont {
        isBold ? .boldSystemFont(ofSize: pointSize) : .systemFont(ofSize: pointSize)
    }

    /// This style's font in a specific typeface (nil = system default),
    /// keeping the style's point size and weight. Falls back to the system
    /// font if `familyName` can't be resolved (e.g. a project font that's no
    /// longer installed).
    func font(familyName: String?) -> NSFont {
        font.withFamily(familyName)
    }
}

extension NSFont {
    /// This font re-created in a different family, preserving point size and
    /// bold/italic traits. `nil` means "system default". Falls back to `self`
    /// if the family can't resolve a matching font.
    func withFamily(_ familyName: String?) -> NSFont {
        guard let familyName else { return self }
        var traits: NSFontTraitMask = []
        if fontDescriptor.symbolicTraits.contains(.bold) { traits.insert(.boldFontMask) }
        if fontDescriptor.symbolicTraits.contains(.italic) { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: familyName, traits: traits, weight: 5, size: pointSize) ?? self
    }
}

@MainActor
final class RichTextController: ObservableObject {

    /// The text view currently driven by this controller. Set by RichTextEditor.
    weak var textView: NSTextView?

    static let defaultBodyFont = NSFont.systemFont(ofSize: 14)

    /// The project's chosen typeface (nil = system default). Set by
    /// ChapterDetailView from `Project.bodyFontFamily`; every font this
    /// controller applies goes through it so typed/styled text matches the
    /// project-wide font.
    var fontFamilyName: String?

    /// The style the cursor (or the start of the selection) is currently in —
    /// drives the checkmark in the Style menu. `@Published` (not just a plain
    /// method) because nothing else about this controller changes when the
    /// cursor merely moves within the text view: without a published property
    /// to trigger it, SwiftUI has no signal to ever recompute FormatToolbar,
    /// so the checkmark would just freeze at whatever it was on first render.
    /// Kept up to date by `RichTextEditor.Coordinator.textViewDidChangeSelection`.
    @Published private(set) var currentStyle: TextStyle = .body

    /// The callout kind the cursor (or start of selection) sits inside, or `nil`
    /// in ordinary body text. Drives the checkmark in the Callout menu; kept in
    /// sync by `selectionDidChange`, for the same reason `currentStyle` is.
    @Published private(set) var currentCallout: CalloutKind?

    private var bodyFont: NSFont { TextStyle.body.font(familyName: fontFamilyName) }

    // MARK: - Images

    func chooseImage() {
        guard let textView else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Insert"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let image = NSImage(contentsOf: url)
            else { return }
            self?.insertImage(image)
        }

        if let window = textView.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func insertImage(_ image: NSImage) {
        guard let textView else { return }
        let maximumWidth = (textView as? PagedTextView)?.pageLayout.contentWidth
            ?? textView.textContainer?.containerSize.width
            ?? image.size.width
        RichTextImageInserter.insert(
            image,
            into: textView,
            at: textView.selectedRange(),
            maximumWidth: maximumWidth
        )
    }

    // MARK: - Navigation

    /// Scrolls the editor to a character range (used by the outline to jump to
    /// a heading, and by project-wide Find to jump to a match) and selects it,
    /// so the destination text is actually visible/highlighted rather than
    /// just placing a collapsed cursor at its start.
    func scroll(to range: NSRange) {
        // In the per-page editor the target may live on a different page than
        // the focused one, and a page view's scrollRangeToVisible only
        // understands its own container. Let the stack resolve it.
        if let stack = (textView as? PageTextView)?.pageStack {
            stack.scroll(toCharacterRange: range)
            return
        }
        guard let textView, range.location != NSNotFound else { return }
        let length = textView.textStorage?.length ?? 0
        guard range.location <= length else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, length - range.location))
        textView.scrollRangeToVisible(clamped)
        textView.setSelectedRange(clamped)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Character formatting

    func toggleBold() { toggleSymbolicTrait(.bold) }
    func toggleItalic() { toggleSymbolicTrait(.italic) }

    private func toggleSymbolicTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let textView else { return }
        let range = textView.selectedRange()

        // No selection: flip the trait for newly typed text.
        if range.length == 0 {
            let current = (textView.typingAttributes[.font] as? NSFont) ?? bodyFont
            let isOn = current.fontDescriptor.symbolicTraits.contains(trait)
            textView.typingAttributes[.font] = font(current, setting: trait, on: !isOn)
            return
        }

        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: range, replacementString: nil) else { return }

        // If every run already has the trait, turn it off; otherwise turn it on.
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
            let runFont = (value as? NSFont) ?? bodyFont
            if !runFont.fontDescriptor.symbolicTraits.contains(trait) { allHaveTrait = false }
        }
        let turnOn = !allHaveTrait

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let runFont = (value as? NSFont) ?? bodyFont
            storage.addAttribute(.font, value: font(runFont, setting: trait, on: turnOn), range: subRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func font(_ font: NSFont, setting trait: NSFontDescriptor.SymbolicTraits, on: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Paragraph styles (headings)

    /// Recomputes `currentStyle` from the font at the cursor (or the start of
    /// the selection), classified the same way `WordDocumentExporter` maps
    /// fonts back to Word heading styles: bold size bands, else body. Called
    /// on every selection change and after applying a style.
    func selectionDidChange() {
        guard let textView else {
            currentStyle = .body
            currentCallout = nil
            return
        }
        let location = textView.selectedRange().location
        let storageLength = textView.textStorage?.length ?? 0
        // Classify the callout at the cursor. At end-of-text (location ==
        // length) there's no character to read, so report no callout.
        if location < storageLength,
           let raw = textView.textStorage?.attribute(.inklingCallout, at: location, effectiveRange: nil) as? String {
            currentCallout = CalloutKind(storedRawValue: raw)
        } else {
            currentCallout = nil
        }

        let font: NSFont?
        if location < storageLength {
            font = textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        } else {
            font = textView.typingAttributes[.font] as? NSFont
        }
        guard let font else {
            currentStyle = .body
            return
        }
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
        if bold && font.pointSize >= 25 { currentStyle = .title }
        else if bold && font.pointSize >= 19 { currentStyle = .heading }
        else if bold && font.pointSize >= 15 { currentStyle = .subheading }
        else { currentStyle = .body }
    }

    func applyStyle(_ style: TextStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        guard textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }

        let font = style.font(familyName: fontFamilyName)
        storage.addAttribute(.font, value: font, range: paragraphRange)
        textView.typingAttributes[.font] = font
        textView.didChangeText()
        selectionDidChange()
    }

    // MARK: - Callouts

    /// Wraps the selection's paragraph(s) in a callout of `kind` (or re-tags an
    /// existing callout to a different kind). Operates on whole paragraphs, like
    /// `applyStyle`, so a callout is always a clean run of paragraphs.
    func applyCallout(_ kind: CalloutKind) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        guard range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) else { return }

        storage.beginEditing()
        CalloutStyling.apply(kind, to: storage, range: range)
        storage.endEditing()
        textView.didChangeText()
        (textView as? PagedTextView)?.updatePageLayout()
        textView.needsDisplay = true
        selectionDidChange()
    }

    /// Removes any callout covering the selection's paragraph(s), resetting them
    /// to plain body paragraphs.
    func removeCallout() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        guard range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) else { return }

        storage.beginEditing()
        CalloutStyling.remove(from: storage, range: range)
        storage.endEditing()
        textView.didChangeText()
        (textView as? PagedTextView)?.updatePageLayout()
        textView.needsDisplay = true
        selectionDidChange()
    }

    // MARK: - Floating sidebar

    /// Inserts a floating margin sidebar at the caret and enters it for typing.
    func insertSidebar() {
        if let page = textView as? PageTextView {
            page.pageStack?.insertSidebar()
            return
        }
        (textView as? PagedTextView)?.insertSidebar()
    }

    // MARK: - Bullet list

    /// Toggles a simple bullet ("• ⇥") prefix on every paragraph touched by the
    /// selection. Applied/removed uniformly: if all are already bulleted, it
    /// removes them; otherwise it adds them.
    func toggleBulletList() {
        guard let textView, let storage = textView.textStorage else { return }
        let full = textView.string as NSString
        let selectionParagraphs = full.paragraphRange(for: textView.selectedRange())
        guard textView.shouldChangeText(in: selectionParagraphs, replacementString: nil) else { return }

        let marker = "•\t"
        let markerLength = (marker as NSString).length

        var paragraphStarts: [Int] = []
        full.enumerateSubstrings(in: selectionParagraphs, options: [.byParagraphs, .substringNotRequired]) { _, subRange, _, _ in
            paragraphStarts.append(subRange.location)
        }

        let allBulleted = !paragraphStarts.isEmpty && paragraphStarts.allSatisfy { location in
            location + markerLength <= full.length
                && full.substring(with: NSRange(location: location, length: markerLength)) == marker
        }

        storage.beginEditing()
        // Edit back-to-front so earlier locations stay valid.
        for location in paragraphStarts.sorted(by: >) {
            if allBulleted {
                storage.replaceCharacters(in: NSRange(location: location, length: markerLength), with: "")
            } else {
                let attributedMarker = NSAttributedString(
                    string: marker,
                    attributes: [.font: (textView.typingAttributes[.font] as? NSFont) ?? bodyFont]
                )
                storage.replaceCharacters(in: NSRange(location: location, length: 0), with: attributedMarker)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }
}
