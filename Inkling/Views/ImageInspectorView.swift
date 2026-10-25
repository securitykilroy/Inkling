//
//  ImageInspectorView.swift
//  Inkling
//
//  Nonmodal controls for the selected manuscript image.
//

import SwiftUI

struct ImageInspectorView: View {
    @State private var caption: String
    @State private var followsText: Bool
    let onApply: (String, Bool) -> Void
    let onRemoveCaption: () -> Void

    init(
        caption: String?,
        followsText: Bool,
        onApply: @escaping (String, Bool) -> Void,
        onRemoveCaption: @escaping () -> Void
    ) {
        _caption = State(initialValue: caption ?? "")
        _followsText = State(initialValue: followsText)
        self.onApply = onApply
        self.onRemoveCaption = onRemoveCaption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image Settings")
                .font(.headline)

            Text("Caption")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $caption)
                .font(.body)
                .frame(minHeight: 76)
                .accessibilityLabel("Image caption")
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.separator, lineWidth: 1)
                }

            Toggle("Follow text as the document changes", isOn: $followsText)
                .accessibilityHint("Turn off to lock the image to its current page")

            HStack {
                Button("Remove Caption") {
                    caption = ""
                    onRemoveCaption()
                }
                .disabled(ImageCaption.normalized(caption) == nil)

                Spacer()

                Button("Apply") {
                    onApply(caption, followsText)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
