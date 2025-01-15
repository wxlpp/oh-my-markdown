//
//  ContentView.swift
//  iOS Example
//
//  Created by Evan Wang on 2025年1月15日.
//

import MarkdownKit
import SwiftUI

struct SwiftUIMarkdownKit: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        MarkdownKit()
    }

    func updateUIView(_: UIView, context _: Context) {}
}

struct ContentView: View {
    var body: some View {
        VStack(alignment: .center) {
            SwiftUIMarkdownKit()
        }
    }
}

#Preview {
    ContentView()
}
