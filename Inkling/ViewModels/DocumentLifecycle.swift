//
//  DocumentLifecycle.swift
//  Inkling
//
//  Tells a project window's SwiftUI layer that its document is going away.
//
//  A window and the SwiftUI tree inside it can outlive the document's Core Data
//  stack by a few turns of the run loop: AppKit may run one more layout pass —
//  from a display-cycle observer, or from the nested event loop
//  `-[NSApplication _shouldTerminate]` spins to ask about unsaved changes —
//  after the document has closed and its persistent store has been torn down.
//  Any view that reads a fetched `Chapter` in that window faults it out of a
//  dead store, and Core Data raises `NSInvalidArgumentException` from
//  `-[NSManagedObjectContext objectWithID:]`, which is an uncaught exception
//  inside AppKit's layout and therefore a crash.
//
//  Two ordinary things reach that state: quitting, and opening a document while
//  a pristine untitled window is showing (`InklingDocumentController` closes the
//  untitled document once the real one is open).
//
//  The document sets `isClosing` synchronously at the top of `close()` — before
//  the store goes anywhere — and the root view stops rendering anything that
//  touches the context. Whenever that late layout pass lands, there is nothing
//  left in the tree that would fault an object.
//

import SwiftUI
import Combine

@MainActor
final class DocumentLifecycle: ObservableObject {
    /// Set once and never cleared: a closed document is never reopened in
    /// place, so there is no path back to `false`.
    @Published private(set) var isClosing = false

    func documentIsClosing() { isClosing = true }
}
