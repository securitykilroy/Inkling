//
//  FormatToolbar.swift
//  Inkling
//
//  Formatting controls for the rich-text editor: paragraph style (heading
//  levels), bold, italic, and bullet list. Each control forwards to the
//  RichTextController, which applies it to the underlying NSTextView.
//

import SwiftUI

struct FormatToolbar: View {
    @ObservedObject var controller: RichTextController

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(TextStyle.allCases) { style in
                    Button {
                        controller.applyStyle(style)
                    } label: {
                        if style == controller.currentStyle {
                            Label(style.label, systemImage: "checkmark")
                        } else {
                            Text(style.label)
                        }
                    }
                }
            } label: {
                Label("Style", systemImage: "textformat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 16)

            Button { controller.toggleBold() } label: {
                Image(systemName: "bold")
            }
            .keyboardShortcut("b", modifiers: .command)
            .help("Bold (⌘B)")

            Button { controller.toggleItalic() } label: {
                Image(systemName: "italic")
            }
            .keyboardShortcut("i", modifiers: .command)
            .help("Italic (⌘I)")

            Button { controller.toggleBulletList() } label: {
                Image(systemName: "list.bullet")
            }
            .help("Bullet List")

            Divider().frame(height: 16)

            Menu {
                ForEach(CalloutKind.allCases) { kind in
                    Button {
                        controller.applyCallout(kind)
                    } label: {
                        if kind == controller.currentCallout {
                            Label(kind.menuLabel, systemImage: "checkmark")
                        } else {
                            Label(kind.menuLabel, systemImage: kind.symbolName)
                        }
                    }
                }
                Divider()
                Button("Remove Callout") { controller.removeCallout() }
                    .disabled(controller.currentCallout == nil)
            } label: {
                Label("Callout", systemImage: "text.bubble")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Wrap the selected paragraphs in a Note or Warning callout box")

            Button { controller.insertSidebar() } label: {
                Image(systemName: "sidebar.squares.right")
            }
            .help("Insert a floating Sidebar the text wraps around")

            Divider().frame(height: 16)

            Button { controller.chooseImage() } label: {
                Image(systemName: "photo.badge.plus")
            }
            .help("Insert Image")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .background(styleShortcuts)
    }

    /// Keyboard shortcuts for the paragraph styles. These live in the regular
    /// view hierarchy (not inside the Style menu) so SwiftUI actually registers
    /// them as key equivalents — shortcuts on buttons nested in a Menu are not.
    private var styleShortcuts: some View {
        ZStack {
            ForEach(TextStyle.allCases) { style in
                Button("") { controller.applyStyle(style) }
                    .keyboardShortcut(shortcutKey(for: style), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutKey(for style: TextStyle) -> KeyEquivalent {
        switch style {
        case .title: return "1"
        case .heading: return "2"
        case .subheading: return "3"
        case .body: return "0"
        }
    }
}
