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

    var font: NSFont {
        switch self {
        case .title: return .boldSystemFont(ofSize: 28)
        case .heading: return .boldSystemFont(ofSize: 22)
        case .subheading: return .boldSystemFont(ofSize: 17)
        case .body: return .systemFont(ofSize: 14)
        }
    }
}

@MainActor
final class RichTextController: ObservableObject {

    /// The text view currently driven by this controller. Set by RichTextEditor.
    weak var textView: NSTextView?

    static let defaultBodyFont = NSFont.systemFont(ofSize: 14)

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
    /// a heading) and places the cursor there.
    func scroll(to range: NSRange) {
        guard let textView, range.location != NSNotFound else { return }
        let length = textView.textStorage?.length ?? 0
        guard range.location <= length else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, length - range.location))
        textView.scrollRangeToVisible(clamped)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
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
            let current = (textView.typingAttributes[.font] as? NSFont) ?? Self.defaultBodyFont
            let isOn = current.fontDescriptor.symbolicTraits.contains(trait)
            textView.typingAttributes[.font] = font(current, setting: trait, on: !isOn)
            return
        }

        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: range, replacementString: nil) else { return }

        // If every run already has the trait, turn it off; otherwise turn it on.
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
            let runFont = (value as? NSFont) ?? Self.defaultBodyFont
            if !runFont.fontDescriptor.symbolicTraits.contains(trait) { allHaveTrait = false }
        }
        let turnOn = !allHaveTrait

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let runFont = (value as? NSFont) ?? Self.defaultBodyFont
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

    func applyStyle(_ style: TextStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
        guard textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }

        storage.addAttribute(.font, value: style.font, range: paragraphRange)
        textView.typingAttributes[.font] = style.font
        textView.didChangeText()
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
                    attributes: [.font: (textView.typingAttributes[.font] as? NSFont) ?? Self.defaultBodyFont]
                )
                storage.replaceCharacters(in: NSRange(location: location, length: 0), with: attributedMarker)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }
}
