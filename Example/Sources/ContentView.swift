//
//  ContentView.swift
//  iOS Example
//
//  Created by Evan Wang on 2025年1月15日.
//

import SwiftUI
import MarkdownKit

struct SwiftUIMarkdownKit: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        return MarkdownKit()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
    }
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
