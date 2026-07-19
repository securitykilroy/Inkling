//
//  SidebarTextView.swift
//  Inkling
//
//  The editable box for one floating margin sidebar. It's a real NSTextView
//  added as a subview of the paged editor, so it scales and scrolls with the
//  page and gives a genuine caret, selection, undo, and spell-check inside the
//  box. It draws its own bordered/tinted chrome and the "SIDEBAR" header, and
//  reserves the header band by offsetting its text container origin.
//
//  Select-then-edit: while "not entered" it declines hit-testing so clicks fall
//  through to PagedTextView, which manages selection/drag/resize. Double-clicking
//  the box enters it (first responder + editable); clicking away exits.
//

import AppKit

final class SidebarTextView: NSTextView {

    /// Called after the text changes, so PagedTextView can push the new content
    /// back into the anchor attachment, re-measure the box, and dirty the doc.
    var onEdited: (() -> Void)?
    /// Called when the box stops being edited (lost first responder), so the
    /// host can drop the "entered" state and redraw selection chrome.
    var onExit: (() -> Void)?

    /// Whether the box is currently being typed into. While false the box is a
    /// passive, click-through object the host selects/moves; while true it edits.
    var isEntered = false {
        didSet {
            isEditable = isEntered
            isSelectable = isEntered
            needsDisplay = true
        }
    }

    static func make(width: CGFloat) -> SidebarTextView {
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
        view.font = NSFont.systemFont(ofSize: 12)
        view.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
            .paragraphStyle: RichTextCodec.defaultParagraphStyle,
        ]
        return view
    }

    /// Text is inset below the header band and within the side padding.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: SidebarStyle.padding, y: SidebarStyle.headerHeight + SidebarStyle.padding)
    }

    /// Passive until entered: decline hit-testing so clicks reach the host, which
    /// owns selection/drag. Once entered, behave like a normal text view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEntered ? super.hitTest(point) : nil
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

        (SidebarStyle.headerLabel as NSString).draw(
            at: NSPoint(x: SidebarStyle.padding, y: 5),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: SidebarStyle.accentColor,
            ]
        )

        super.draw(dirtyRect)

        SidebarStyle.accentColor.setStroke()
        path.lineWidth = SidebarStyle.borderWidth
        path.stroke()
    }
}
