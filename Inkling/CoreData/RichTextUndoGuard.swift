//
//  RichTextUndoGuard.swift
//  Inkling
//
//  Keeps Undo and Redo from rewriting a chapter's text.
//
//  The editors rewrite a rich-text blob on every keystroke, and those writes
//  are deliberately kept off Core Data's undo stack (`assignRichTextIfChanged`)
//  — the text views have their own undo, and Core Data's copy cost a full
//  chapter per keystroke. But Core Data undoes an edit by putting back a
//  snapshot of the *whole object* as it was when that edit was made. So after
//  "rename the chapter, then write in it for an hour", undoing the rename put
//  back the hour-old body along with the old title. Reordering chapters did
//  the same through `sortIndex`.
//
//  The rule this enforces: an undo or redo never changes a rich-text blob on
//  an object that exists both before and after it. The values are noted just
//  before the undo manager acts and put back, outside undo registration, just
//  after. Undoing an insert or a delete is untouched — the object isn't there
//  on one side — and a delete's own snapshot is taken at the moment of
//  deletion, so it is current.
//
//  It follows that nothing which writes a blob can be undone through Core
//  Data, so nothing should register one: Replace All and a project font
//  change write outside its undo as well. An operation that *should* be
//  undoable registers its own action and tells the guard which values it
//  means to change (`accept`); see `applyRichTextChanges`.
//

import AppKit
import CoreData

final class RichTextUndoGuard {

    /// Attributes that aren't blobs but are written outside undo alongside
    /// them, by entity name. A font change restyles every blob and records
    /// the family here; an undo that put back only the family would leave
    /// the two disagreeing.
    static let companionKeys: [String: [String]] = ["Project": ["bodyFontFamily"]]

    private weak var document: NSPersistentDocument?
    private var observers: [NSObjectProtocol] = []
    private var held: [(object: NSManagedObject, values: [String: NSObject?])] = []
    /// True between an undo manager's will- and did- notifications.
    private var isHolding = false

    init(document: NSPersistentDocument) {
        self.document = document
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.capture(from: sender) }
            })
        }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.restore(from: sender) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The document's context, if `sender` is its undo manager. Resolved per
    /// notification: the context doesn't exist yet when the document is made.
    private func context(for sender: ObjectIdentifier?) -> NSManagedObjectContext? {
        guard let context = document?.managedObjectContext,
              let undoManager = context.undoManager,
              ObjectIdentifier(undoManager) == sender
        else { return nil }
        return context
    }

    private static func guardedKeys(of object: NSManagedObject) -> [String] {
        let blobs = object.entity.attributesByName
            .filter { $0.value.attributeType == .binaryDataAttributeType }
            .map(\.key)
        return blobs + (companionKeys[object.entity.name ?? ""] ?? [])
    }

    /// Called by an explicit undo action, while it runs, for each blob it
    /// changes on purpose: `value` is what that key should hold once the
    /// undo or redo has finished. Without this the guard would put the old
    /// value straight back. Does nothing outside an undo or redo.
    func accept(_ value: NSObject?, forKey key: String, of object: NSManagedObject) {
        guard isHolding else { return }
        if let index = held.firstIndex(where: { $0.object === object }) {
            held[index].values.updateValue(value, forKey: key)
        } else {
            held.append((object, [key: value]))
        }
    }

    private func capture(from sender: ObjectIdentifier?) {
        held.removeAll()
        guard let context = context(for: sender) else { return }
        isHolding = true
        // Bring Core Data's own bookkeeping up to date first, so what is
        // noted here is what the undo is about to act on.
        context.processPendingChanges()
        // A fault holds no unsaved typing to protect, and reading it would
        // load every chapter in the project on each undo.
        for object in context.registeredObjects where !object.isFault && !object.isDeleted {
            var values: [String: NSObject?] = [:]
            for key in Self.guardedKeys(of: object) {
                values.updateValue(object.value(forKey: key) as? NSObject, forKey: key)
            }
            if !values.isEmpty { held.append((object, values)) }
        }
    }

    private func restore(from sender: ObjectIdentifier?) {
        guard let context = context(for: sender), let undoManager = context.undoManager else { return }
        let noted = held
        held.removeAll()
        isHolding = false

        context.processPendingChanges()
        undoManager.disableUndoRegistration()
        for (object, values) in noted where !object.isDeleted && object.managedObjectContext != nil {
            for (key, value) in values {
                let current = object.value(forKey: key) as? NSObject
                let unchanged = current.map { $0.isEqual(value) } ?? (value == nil)
                if !unchanged { object.setValue(value, forKey: key) }
            }
        }
        // Inside the disabled window, as in `assignRichTextIfChanged`: Core
        // Data registers undo when it processes changes, not at assignment.
        context.processPendingChanges()
        undoManager.enableUndoRegistration()
    }
}
