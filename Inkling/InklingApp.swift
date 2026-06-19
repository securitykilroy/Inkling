//
//  InklingApp.swift
//  Inkling
//
//  Created by Ric Messier on 6/19/26.
//

import SwiftUI

@main
struct InklingApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: InklingDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
