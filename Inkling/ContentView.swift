//
//  ContentView.swift
//  Inkling
//
//  Created by Ric Messier on 6/19/26.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: InklingDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(InklingDocument()))
}
