//
//  ContentView.swift
//  iOS Example
//
//  Created by Evan Wang on 2025年1月15日.
//

import MarkdownKit
import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TextKitLabel Demo")
                .font(.title2)

            let sampleText = """
            Here is a long text example demonstrating TextKit-based label.
            支持多行显示，自动换行与截断。
            This line is intentionally long to demonstrate wrapping and sizing behavior.
            """
            TextKitLabelView(text: sampleText)
                .frame(width: 300, height: 400)
                .background {
                Color.red
            }
        }
    }
}

#Preview {
    ContentView()
}
