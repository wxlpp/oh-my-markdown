//
//  ExampleTests.swift
//  ExampleTests
//
//  Created by Evan Wang on 2025年1月15日.
//

import MarkdownCore
import Testing

struct ExampleTests {
    @Test("Smoke markdown parses one heading")
    func smokeMarkdownParsesOneHeading() {
        let document = MarkdownDocument(parsing: "# Smoke")

        #expect(document.blocks == [.heading(level: 1, content: [.text("Smoke")])])
    }
}
