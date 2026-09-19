//
//  SidebarTextView.swift
//  Inkling
//
//  The editable box for one floating margin sidebar. It's a real NSTextView
//  added as a subview of the paged editor, so it scales and scrolls with the
//  page and gives a genuine caret, selection, undo, and spell-check inside the
//  box. It draws its own bordered/tinted chrome and its title header, and
//  reserves the header band by offsetting its text container origin.
//
//  The header band is also the rename target: double-clicking it swaps in a
//  text field (see `beginTitleEditing`) rather than entering the box's text.
//
//  Select-then-edit: while "not entered" it declines hit-testing so clicks fall
//  through to PageStackView, which manages selection/drag/resize. Double-clicking
//  the box enters it (first responder + editable); clicking away exits.
//

import AppKit

final class SidebarTextView: NSTextView, NSTextFieldDelegate {

    /// Called after the text changes, so PageStackView can push the new content
    /// back into the anchor attachment, re-measure the box, and dirty the doc.
    var onEdited: (() -> Void)?
    /// Called when the box stops being edited (lost first responder), so the
    /// host can drop the "entered" state and redraw selection chrome.
    var onExit: (() -> Void)?
    /// Called with the committed title when the author finishes renaming the
    /// box, so the host can push it into the anchor and dirty the document.
    var onTitleEdited: ((String) -> Void)?

    /// The header band's label. Held here (rather than read from the anchor) so
    /// the view can draw without reaching back into the text storage.
    var title: String = "" {
        didSet { needsDisplay = true }
    }

    /// What the band actually draws — see `SidebarAttachment.displayTitle`.
    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SidebarStyle.defaultTitle : trimmed
    }

    /// Whether the box is currently being typed into. While false the box is a
    /// passive, click-through object the host selects/moves; while true it edits.
    var isEntered = false {
        didSet {
            isEditable = isEntered
            isSelectable = isEntered
            needsDisplay = true
        }
    }

    /// See `PageTextView.paste` — a sidebar is an editor too, so text pasted
    /// into one adopts the box's styling rather than the source's.
    override func paste(_ sender: Any?) {
        let font = typingAttributes[.font] as? NSFont
        let paragraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let before = selectedRange().location
        super.paste(sender)
        PasteStyling.adoptDestinationStyle(
            in: self,
            range: PasteStyling.pastedRange(from: before, to: selectedRange().location),
            font: font,
            paragraphStyle: paragraphStyle
        )
    }

    @objc func pasteWithFormatting(_ sender: Any?) {
        super.paste(sender)
    }

    static func make(width: CGFloat, fontFamilyName: String? = nil) -> SidebarTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: SidebarStyle.textWidth(forBoxWidth: width),
            height: .greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let view = SidebarTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: SidebarStyle.boxHeight(forContentHeight: 0)),
            textContainer: container
        )
        view.drawsBackground = false
        view.isRichText = true
        view.allowsUndo = true
        view.isEditable = false
        view.isSelectable = false
        view.textContainerInset = .zero
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textColor = .black
        view.insertionPointColor = .black
        let font = NSFont.systemFont(ofSize: 12).withFamily(fontFamilyName)
        view.font = font
        view.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: RichTextCodec.defaultParagraphStyle,
        ]
        return view
    }

    /// Updates only future typing. Existing sidebar text is restyled in its
    /// encoded attachment by `ProjectFontStyler` and reloaded separately.
    func setTypingFontFamily(_ familyName: String?) {
        let current = typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
        var attributes = typingAttributes
        attributes[.font] = current.withFamily(familyName)
        typingAttributes = attributes
    }

    /// Text is inset below the header band and within the side padding.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: SidebarStyle.padding, y: SidebarStyle.headerHeight + SidebarStyle.padding)
    }

    /// Passive until entered: decline hit-testing so clicks reach the host, which
    /// owns selection/drag. Once entered, behave like a normal text view.
    ///
    /// The title field is the exception. It only exists while the author is
    /// renaming the box, and the box is *not* "entered" then — without this
    /// carve-out every click in the field would fall through to the page view
    /// and be read as a press on the box, ending the rename on the first click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let field = titleField, field.frame.contains(local) {
            return field.hitTest(local) ?? field
        }
        // The header band is chrome, not text, so it always belongs to the host
        // page view — which owns selecting, dragging, and the rename gesture.
        // Without this, entering a box swallowed clicks on its own top edge:
        // the box could only be dragged from lower down, and double-clicking
        // the header to rename it did nothing while the box was entered.
        if isInHeaderBand(local) { return nil }
        return isEntered ? super.hitTest(point) : nil
    }

    // MARK: - Title editing

    /// The rename field, alive only while renaming. Its presence is the "is
    /// being renamed" state, so there is no second flag to keep in sync.
    private var titleField: NSTextField?

    /// Whether `point` (in this view's coordinates) lands on the header band,
    /// which is the rename target rather than part of the box's text.
    func isInHeaderBand(_ point: NSPoint) -> Bool {
        point.y >= 0 && point.y < SidebarStyle.headerHeight
            && point.x >= 0 && point.x < bounds.width
    }

    /// Opens the header band for renaming, seeded with the current title and
    /// fully selected so typing replaces it.
    func beginTitleEditing() {
        guard titleField == nil else { return }
        let field = NSTextField(frame: NSRect(
            x: SidebarStyle.padding,
            y: 3,
            width: max(20, bounds.width - SidebarStyle.padding * 2),
            height: SidebarStyle.headerHeight - 6
        ))
        field.stringValue = title
        // The placeholder shows the fallback, so an author who clears the field
        // can see what the band will read instead of guessing.
        field.placeholderString = SidebarStyle.defaultTitle
        field.font = NSFont.boldSystemFont(ofSize: 10)
        field.textColor = SidebarStyle.accentColor
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .white
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        titleField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Commits whatever is in the field and tears it down. Committing on *any*
    /// end of editing — Return, Tab, or clicking away — means a rename is never
    /// silently discarded.
    func endTitleEditing() {
        guard let field = titleField else { return }
        titleField = nil
        let committed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        needsDisplay = true
        if committed != title {
            title = committed
            onTitleEdited?(committed)
        }
    }

    var isEditingTitle: Bool { titleField != nil }

    /// The live rename field, so tests can drive a rename without a real
    /// window's focus machinery.
    var titleFieldForTesting: NSTextField? { titleField }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTitleEditing()
    }

    /// Escape abandons the rename; Return commits it (via end-editing above).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        titleField?.removeFromSuperview()
        titleField = nil
        needsDisplay = true
        window?.makeFirstResponder(superview)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isEntered {
            isEntered = false
            onExit?()
        }
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        onEdited?()
    }

    func load(_ data: Data?) {
        if let data, let attributed = RichTextCodec.decode(data) {
            textStorage?.setAttributedString(attributed)
        } else {
            string = ""
        }
    }

    func contentRTF() -> Data? {
        RichTextCodec.encode(attributedString())
    }

    /// Height the current text occupies at the current width (excludes the
    /// header/padding chrome). Drives the box's overall height via the attachment.
    func fittingTextHeight() -> CGFloat {
        guard let layoutManager, let textContainer else { return SidebarStyle.minContentHeight }
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }

    func setBoxWidth(_ width: CGFloat) {
        textContainer?.size.width = SidebarStyle.textWidth(forBoxWidth: width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        let path = NSBezierPath(
            roundedRect: box.insetBy(dx: SidebarStyle.borderWidth / 2, dy: SidebarStyle.borderWidth / 2),
            xRadius: SidebarStyle.cornerRadius,
            yRadius: SidebarStyle.cornerRadius
        )
        SidebarStyle.fillColor.setFill()
        path.fill()

        // While renaming, the field covers the band and draws the text itself.
        if titleField == nil {
            (displayTitle as NSString).draw(
                at: NSPoint(x: SidebarStyle.padding, y: 5),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 10),
                    .foregroundColor: SidebarStyle.accentColor,
                ]
            )
        }

        super.draw(dirtyRect)

        SidebarStyle.accentColor.setStroke()
        path.lineWidth = SidebarStyle.borderWidth
        path.stroke()
    }
}
