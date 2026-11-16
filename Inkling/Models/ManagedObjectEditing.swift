//
//  ManagedObjectEditing.swift
//  Inkling
//
//  Core Data treats any assignment to a managed property as an edit, even one
//  that stores the value already there. SwiftUI text fields do exactly that:
//  a `TextField` pushes its unchanged text back through its binding while the
//  window first lays out. Each such write dirtied the document, so merely
//  opening a project made closing it ask to save. Bindings that write into
//  Core Data go through `assignIfChanged` so only a real change counts.
//

import AppKit
import CoreData

func assignIfChanged<Root: AnyObject, Value: Equatable>(
    _ root: Root,
    _ keyPath: ReferenceWritableKeyPath<Root, Value>,
    _ value: Value
) {
    guard root[keyPath: keyPath] != value else { return }
    root[keyPath: keyPath] = value
}

/// For rich-text blobs that the editors rewrite on every keystroke (chapter
/// body and notes, shelf entries, project notes). Stores the value without
/// registering it with the context's undo manager, then marks the owning
/// document edited directly.
///
/// The text views keep their own undo stacks, so Core Data's copy was never
/// used for undoing typing. But it kept the *previous* encoded chapter,
/// images included, once per keystroke: measured at 1 GB after 200 edits to a
/// 5 MB chapter. Core Data registers undo when it processes pending changes,
/// not at assignment, so the change is flushed inside the disabled window.
@MainActor
func assignRichTextIfChanged<Root: NSManagedObject>(
    _ root: Root,
    _ keyPath: ReferenceWritableKeyPath<Root, Data?>,
    _ value: Data?
) {
    assignOutsideUndoIfChanged(root, keyPath, value)
}

/// Stores a value without registering it with the context's undo manager,
/// then marks the owning document edited directly.
///
/// Every write to a rich-text blob goes through here, bulk rewrites (Replace
/// All, a project font change) included, and so does anything written
/// alongside one. See `RichTextUndoGuard` for why none of them may be on
/// Core Data's undo stack.
@MainActor
func assignOutsideUndoIfChanged<Root: NSManagedObject, Value: Equatable>(
    _ root: Root,
    _ keyPath: ReferenceWritableKeyPath<Root, Value>,
    _ value: Value
) {
    guard root[keyPath: keyPath] != value else { return }
    guard let context = root.managedObjectContext,
          let undoManager = context.undoManager
    else {
        root[keyPath: keyPath] = value
        return
    }
    context.processPendingChanges()
    undoManager.disableUndoRegistration()
    root[keyPath: keyPath] = value
    context.processPendingChanges()
    undoManager.enableUndoRegistration()
    // Document dirtiness is driven by undo registration, which this skipped.
    NSDocumentController.shared.documents
        .first { ($0 as? NSPersistentDocument)?.managedObjectContext === context }?
        .updateChangeCount(.changeDone)
}
