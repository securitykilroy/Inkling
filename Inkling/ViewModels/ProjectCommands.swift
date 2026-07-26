//
//  ProjectCommands.swift
//  Inkling
//
//  Bridges AppKit menu commands into a project window's SwiftUI layer. Menu
//  items use nil targets and route through the responder chain to the active
//  `InklingDocument`; for commands that drive SwiftUI-owned UI (the Project
//  Settings sheet) or that need view-model/selection state the document can't
//  reach directly (New Chapter), the document pokes this object and the SwiftUI
//  views observe it. The document owns one instance per window and injects it
//  into the root view's environment.
//
//  This is the seam that lets SwiftUI-driven features also appear as first-class
//  menu items, instead of being reachable only through in-view controls.
//

import SwiftUI
import Combine

@MainActor
final class ProjectCommands: ObservableObject {
    /// Drives the Project Settings sheet. The sidebar's gear button and the
    /// Settings… menu item both raise this, so there is a single presentation.
    @Published var settingsPresented = false

    /// Drives the project-wide Find & Replace sheet. The sidebar's magnifier
    /// button and the Find & Replace in Project… menu item both raise this.
    @Published var findReplacePresented = false

    /// Bumped by the New Chapter command. A counter rather than a flag so each
    /// invocation registers as a change — even two in a row — letting the
    /// observing view insert and select a chapter once per command.
    @Published var newChapterRequests = 0

    func presentSettings() { settingsPresented = true }

    func presentFindReplace() { findReplacePresented = true }

    func requestNewChapter() { newChapterRequests += 1 }
}
