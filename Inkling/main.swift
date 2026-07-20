//
//  main.swift
//  Inkling
//
//  Programmatic AppKit entry point. Using an explicit main.swift (rather than
//  @main on the delegate) guarantees the application, its delegate, and the
//  hand-built main menu are all installed before the run loop starts. Without
//  a storyboard/xib, macOS does not provide a menu bar — we install our own.
//

import Cocoa

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.mainMenu = MainMenu.build()
    application.setActivationPolicy(.regular)
    application.run()
}
