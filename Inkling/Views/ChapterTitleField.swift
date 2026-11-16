//
//  ChapterTitleField.swift
//  Inkling
//
//  The chapter title above the editor. An AppKit text field rather than a
//  SwiftUI `TextField` for one reason: Undo.
//
//  SwiftUI's field edits through a field editor that keeps a private undo
//  stack. ⌘Z in the title field went to that stack first, which changed the
//  text *in the field* without writing it back, so the field could show a
//  title the chapter didn't have (and a later Undo then appeared to do
//  nothing). Here the field editor keeps no undo of its own and sends Undo to
//  the window's undo manager, the document's. A rename is undone in one place
//  only, the document's undo stack, and the field redraws from the stored
//  title. It also reports where one rename ends and the next begins, so a
//  rename is one undo step (`renameChapter`).
//

import AppKit
import SwiftUI

struct ChapterTitleField: NSViewRepresentable {
    /// The stored title.
    let text: String
    /// Reads the stored title as it is right now. `text` is what SwiftUI last
    /// rendered, which lags fast typing by a keystroke or two; deciding where
    /// a rename begins from it split a quickly typed rename into several
    /// undo steps.
    let storedText: () -> String
    /// Called with each edit. `startsNewEdit` is true for the first change of
    /// a visit to the field, and for the first change after the title was set
    /// from elsewhere (an Undo, say); the keystrokes after it continue that
    /// edit, so the whole rename can be one undo step.
    let onEdit: (_ text: String, _ startsNewEdit: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = TitleTextField()
        field.placeholderString = "Chapter Title"
        field.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize, weight: .bold
        )
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = text
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Chapter Title")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Also while the field is being edited: this is how an Undo of the
        // rename reaches the screen.
        guard field.stringValue != text else { return }
        field.stringValue = text
        if let editor = field.currentEditor(), editor.string != text {
            editor.string = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChapterTitleField
        /// What this visit to the field last wrote; nil before its first edit.
        private var lastWritten: String?

        init(_ parent: ChapterTitleField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let new = field.stringValue
            // The stored title no longer being what we wrote means something
            // else changed it, so this keystroke begins a fresh edit.
            let startsNewEdit = lastWritten == nil || parent.storedText() != lastWritten
            lastWritten = new
            parent.onEdit(new, startsNewEdit)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            lastWritten = nil
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            lastWritten = nil
        }
    }
}

private final class TitleTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { TitleTextFieldCell.self }
        set { }
    }
}

private final class TitleTextFieldCell: NSTextFieldCell {
    private lazy var editor: TitleFieldEditor = {
        let editor = TitleFieldEditor()
        editor.isFieldEditor = true
        editor.allowsUndo = false
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// Keeps no undo of its own; Undo and Redo act on the document's.
///
/// It must not simply *report* the document's undo manager as its own: a text
/// view treats its undo manager as private and empties it whenever its text is
/// replaced from outside, which wiped the document's whole undo stack the
/// first time a rename was undone. So it owns a scratch manager that is never
/// used, and forwards the two commands instead.
private final class TitleFieldEditor: NSTextView {
    private let scratchUndoManager = UndoManager()

    override var undoManager: UndoManager? { scratchUndoManager }

    private var documentUndoManager: UndoManager? { window?.undoManager }

    @objc func undo(_ sender: Any?) {
        guard let manager = documentUndoManager, manager.canUndo else { return }
        manager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let manager = documentUndoManager, manager.canRedo else { return }
        manager.redo()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = documentUndoManager?.undoMenuItemTitle ?? "Undo"
            return documentUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = documentUndoManager?.redoMenuItemTitle ?? "Redo"
            return documentUndoManager?.canRedo ?? false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
