//
//  AppDelegate.swift
//  Inkling
//
//  Application delegate for the AppKit document architecture
//  (NSDocumentController + NSPersistentDocument). The app is launched from
//  main.swift, which installs this delegate and the hand-built main menu.
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The first document-controller instance created during launch becomes
    /// AppKit's shared controller. Keep it alive for the application's life.
    private var documentController: InklingDocumentController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController = InklingDocumentController()
    }

    /// Keep the app running when all document windows close (standard macOS
    /// document-app behavior: the user can make a new document from the Dock
    /// or File menu).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
