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

import Foundation

func assignIfChanged<Root: AnyObject, Value: Equatable>(
    _ root: Root,
    _ keyPath: ReferenceWritableKeyPath<Root, Value>,
    _ value: Value
) {
    guard root[keyPath: keyPath] != value else { return }
    root[keyPath: keyPath] = value
}
