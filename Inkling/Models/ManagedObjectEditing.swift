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

/// One rich-text blob changing from one value to another, as part of an
/// operation the author can undo as a whole.
struct RichTextChange {
    let object: NSManagedObject
    let key: String
    let from: Data?
    let to: Data?
}

/// What to tell the author when undoing (or redoing) a bulk rewrite left some
/// chapters alone because they had been edited in the meantime.
struct RichTextUndoNotice: Equatable {
    let skipped: Int
    let actionName: String
    let isRedo: Bool

    var message: String {
        let step = isRedo ? "Redo \(actionName)" : "Undo \(actionName)"
        return skipped == 1
            ? "\(step) left 1 chapter as it is."
            : "\(step) left \(skipped) chapters as they are."
    }

    var explanation: String {
        let since = isRedo ? "since \(actionName) was undone" : "after \(actionName)"
        return skipped == 1
            ? "1 chapter was changed \(since), so it was not touched. Nothing you wrote was rolled back."
            : "\(skipped) chapters were changed \(since), so they were not touched. Nothing you wrote was rolled back."
    }
}

/// Applies `changes` as a single undoable step — the way a bulk rewrite such
/// as Replace All gets an Undo without going through Core Data's own, which
/// can't be trusted with these blobs (see `RichTextUndoGuard`).
///
/// A change is applied only where the blob still holds exactly `from`. That
/// is what makes the undo safe: a chapter the author has typed in since no
/// longer matches, so it is left as they wrote it rather than rolled back,
/// while every chapter they haven't touched is restored. The inverse that
/// gets registered covers only the changes actually applied, so a redo can't
/// reach the skipped ones either.
///
/// Skipping is never silent on the way back: when an undo or redo leaves
/// chapters as they are, `reportSkipped` is told how many (by default the
/// document says so in a sheet; see `RichTextUndoNotice`).
@MainActor
func applyRichTextChanges(
    _ changes: [RichTextChange],
    actionName: String,
    in context: NSManagedObjectContext,
    reportSkipped: ((RichTextUndoNotice) -> Void)? = nil
) {
    let document = NSDocumentController.shared.documents
        .first { ($0 as? NSPersistentDocument)?.managedObjectContext === context }
    let undoGuard = (document as? InklingDocument)?.undoGuard
    let undoManager = context.undoManager

    var applied: [RichTextChange] = []
    // Still there, but no longer holding the text this step would replace.
    var changedSince = 0
    context.processPendingChanges()
    undoManager?.disableUndoRegistration()
    for change in changes
    where !change.object.isDeleted && change.object.managedObjectContext != nil
        && change.from != change.to {
        guard (change.object.value(forKey: change.key) as? Data) == change.from else {
            changedSince += 1
            continue
        }
        change.object.setValue(change.to, forKey: change.key)
        undoGuard?.accept(change.to as NSData?, forKey: change.key, of: change.object)
        applied.append(change)
    }
    context.processPendingChanges()
    undoManager?.enableUndoRegistration()

    if changedSince > 0, let undoManager, undoManager.isUndoing || undoManager.isRedoing {
        let notice = RichTextUndoNotice(
            skipped: changedSince, actionName: actionName, isRedo: undoManager.isRedoing
        )
        if let reportSkipped {
            reportSkipped(notice)
        } else {
            (document as? InklingDocument)?.present(notice)
        }
    }

    guard !applied.isEmpty, let undoManager else { return }
    let inverse = applied.map {
        RichTextChange(object: $0.object, key: $0.key, from: $0.to, to: $0.from)
    }
    undoManager.registerUndo(withTarget: context) { context in
        applyRichTextChanges(
            inverse, actionName: actionName, in: context, reportSkipped: reportSkipped
        )
    }
    undoManager.setActionName(actionName)
    // The registered action marks the document edited when its undo group
    // closes; say so now as well, so it never depends on that timing.
    if !undoManager.isUndoing, !undoManager.isRedoing {
        document?.updateChangeCount(.changeDone)
    }
}
