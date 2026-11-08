//
//  SQLiteJournalAccess.swift
//  Inkling
//
//  Lets the sandboxed app create SQLite's rollback journal beside a project.
//
//  Saving a SQLite store in place creates `<project>-journal` next to it for
//  the length of the save. The sandbox only grants access to the file the
//  writer opened, so that create was denied and every save failed with
//  SQLite error 21. Two things together extend the grant to the journal:
//  the `inkling-journal` extension is declared as a related item type
//  (`NSIsRelatedItemType` in Info.plist), and a file presenter for the
//  journal names the project as its primary item.
//

import Foundation

final class SQLiteJournalAccess: NSObject, NSFilePresenter {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main

    init(projectURL: URL) {
        primaryPresentedItemURL = projectURL
        presentedItemURL = URL(fileURLWithPath: projectURL.path + "-journal")
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func invalidate() {
        NSFileCoordinator.removeFilePresenter(self)
    }
}
