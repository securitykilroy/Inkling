//
//  MainMenu.swift
//  Inkling
//
//  Builds the application main menu in code (no storyboard/xib). Items use
//  nil targets so they route through the responder chain to whatever object
//  handles them — NSDocumentController for New/Open, the active NSDocument
//  for Save/Revert, the first responder for Edit actions, and so on.
//

import Cocoa

enum MainMenu {

    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeWindowMenu())
        return mainMenu
    }

    // MARK: - Helpers

    private static func item(
        _ title: String,
        _ selector: String,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let container = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        container.submenu = menu
        return container
    }

    // MARK: - App menu

    private static func makeAppMenu() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        return submenu(appName, [
            item("About \(appName)", "orderFrontStandardAboutPanel:", ""),
            .separator(),
            {
                let hideOthers = item("Hide Others", "hideOtherApplications:", "h")
                hideOthers.keyEquivalentModifierMask = [.command, .option]
                return hideOthers
            }(),
            item("Hide \(appName)", "hide:", "h"),
            item("Show All", "unhideAllApplications:", ""),
            .separator(),
            item("Quit \(appName)", "terminate:", "q"),
        ])
    }

    // MARK: - File menu

    private static func makeFileMenu() -> NSMenuItem {
        let saveAs = item("Save As…", "saveDocumentAs:", "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]

        let printChapter = item("Print Chapter…", "printChapter:", "p")
        printChapter.keyEquivalentModifierMask = [.command, .shift]

        let exportText = item("Export as Plain Text…", "exportProjectAsPlainText:", "e")
        exportText.keyEquivalentModifierMask = [.command, .shift]

        let exportWord = item("Export Word Chapters…", "exportWordChapters:", "e")
        exportWord.keyEquivalentModifierMask = [.command, .option]

        // macOS automatically augments a document app's File menu with a
        // populated "Open Recent" plus Close All / Rename / Move To /
        // Revert To (the version browser) / Share, so we don't add those here —
        // doing so produced a duplicate, empty "Open Recent".
        return submenu("File", [
            item("New", "newDocument:", "n"),
            item("Open…", "openDocument:", "o"),
            .separator(),
            item("Close", "performClose:", "w"),
            item("Save…", "saveDocument:", "s"),
            saveAs,
            item("Duplicate", "duplicateDocument:", ""),
            .separator(),
            item("Print Project…", "printProject:", "p"),
            printChapter,
            .separator(),
            item("Import Word Chapters…", "importWordChapters:", ""),
            exportWord,
            exportText,
        ])
    }

    // MARK: - Edit menu

    private static func makeEditMenu() -> NSMenuItem {
        let redo = item("Redo", "redo:", "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        return submenu("Edit", [
            item("Undo", "undo:", "z"),
            redo,
            .separator(),
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            item("Paste", "paste:", "v"),
            item("Delete", "delete:", ""),
            item("Select All", "selectAll:", "a"),
            .separator(),
            makeFindMenu(),
        ])
    }

    /// The standard TextKit find bar, driven through the responder chain by
    /// `performTextFinderAction:`. The item tags are `NSTextFinder.Action` raw
    /// values, which the focused text view reads to decide what to do.
    private static func makeFindMenu() -> NSMenuItem {
        func finderItem(
            _ title: String,
            _ action: NSTextFinder.Action,
            _ key: String,
            modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(NSResponder.performTextFinderAction(_:)),
                keyEquivalent: key
            )
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.tag = action.rawValue
            return item
        }

        return submenu("Find", [
            finderItem("Find…", .showFindInterface, "f"),
            finderItem("Find Next", .nextMatch, "g"),
            finderItem("Find Previous", .previousMatch, "g", modifiers: [.command, .shift]),
            finderItem("Use Selection for Find", .setSearchString, "e"),
        ])
    }

    // MARK: - Window menu

    private static func makeWindowMenu() -> NSMenuItem {
        let windowItem = submenu("Window", [
            item("Minimize", "performMiniaturize:", "m"),
            item("Zoom", "performZoom:", ""),
            .separator(),
            // Title is updated dynamically (Show/Hide) by
            // InklingDocument.validateUserInterfaceItem(_:).
            item("Show Project Notes", "toggleProjectNotes:", ""),
            .separator(),
            item("Bring All to Front", "arrangeInFront:", ""),
        ])
        // Let AppKit manage the list of open windows in this menu.
        NSApp.windowsMenu = windowItem.submenu
        return windowItem
    }
}
