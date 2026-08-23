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
            // An inline Picker, not Buttons: a Button's `Label` image is not
            // drawn inside a menu, so the hand-rolled checkmark that used to
            // mark the current style never appeared and the menu gave no clue
            // which style the caret was in. A Picker draws the mark itself.
            Menu {
                Picker("Style", selection: styleSelection) {
                    ForEach(TextStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
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
                // Same reason as the Style menu above: only a Picker marks the
                // current choice. The selection is optional because the caret
                // is usually not in a callout at all.
                Picker("Callout", selection: calloutSelection) {
                    ForEach(CalloutKind.allCases) { kind in
                        Label(kind.menuLabel, systemImage: kind.symbolName)
                            .tag(CalloutKind?.some(kind))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
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

    /// Reads the style at the caret and applies the one the user picks.
    /// Picking the style that's already current is a no-op — SwiftUI only
    /// writes through a Picker's binding when the selection actually changes.
    private var styleSelection: Binding<TextStyle> {
        Binding(
            get: { controller.currentStyle },
            set: { controller.applyStyle($0) }
        )
    }

    /// Optional because the caret is usually not inside a callout, in which
    /// case no row is marked. Clearing goes through Remove Callout, so a nil
    /// write never reaches here.
    private var calloutSelection: Binding<CalloutKind?> {
        Binding(
            get: { controller.currentCallout },
            set: { if let kind = $0 { controller.applyCallout(kind) } }
        )
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
