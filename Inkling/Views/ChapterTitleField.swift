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
//  only, Core Data's, and the field redraws from the stored title.
//

import AppKit
import SwiftUI

struct ChapterTitleField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

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
        context.coordinator.text = $text
        // Also while the field is being edited: this is how an Undo of the
        // rename reaches the screen.
        guard field.stringValue != text else { return }
        field.stringValue = text
        if let editor = field.currentEditor(), editor.string != text {
            editor.string = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
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
