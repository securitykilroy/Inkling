//
//  ToolTip.swift
//  Inkling
//
//  A reliable hover tooltip for SwiftUI controls hosted inside this app's
//  AppKit window. SwiftUI's `.help(_:)` is supposed to produce a native
//  tooltip, but for icon-only borderless buttons hosted via
//  NSHostingController it does not reliably surface one. Setting `toolTip`
//  on a backing NSView (placed behind the content) makes AppKit own the
//  tooltip rect directly, so the tooltip shows anywhere over the control.
//

import SwiftUI
import AppKit

extension View {
    /// Shows `text` on hover. Keeps `.help(_:)` for accessibility/VoiceOver and
    /// adds an AppKit-backed tooltip so the tip actually appears on screen.
    func tooltip(_ text: String) -> some View {
        self
            .help(text)
            .background(ToolTipBackingView(text: text))
    }
}

private struct ToolTipBackingView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}
