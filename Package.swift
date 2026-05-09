// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MarkdownKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Consumer-facing umbrella product — import MarkdownKit to get SwiftUI views.
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        // Individual layers, available for consumers that only need a subset.
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
        .library(name: "MarkdownRenderKit", targets: ["MarkdownRenderKit"]),
        .library(name: "MarkdownPlatformView", targets: ["MarkdownPlatformView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.3"),
    ],
    targets: [
        // MARK: - MarkdownCore

        // Parses Markdown source via swift-markdown and exposes a typed block tree (IR).
        // No UI, no rendering — pure data model.
        .target(
            name: "MarkdownCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),

        // MARK: - MarkdownRenderKit

        // Converts the block tree into AttributedString / layout fragments.
        // Platform-agnostic; no UIKit / AppKit / SwiftUI imports.
        .target(
            name: "MarkdownRenderKit",
            dependencies: ["MarkdownCore"]
        ),

        // MARK: - MarkdownPlatformView

        // UIKit / AppKit views built on TextKit 2.
        // Handles text selection and streaming updates at the native layer.
        .target(
            name: "MarkdownPlatformView",
            dependencies: ["MarkdownRenderKit"]
        ),

        // MARK: - MarkdownKit

        // SwiftUI layer — thin wrappers around MarkdownPlatformView.
        // This is what most consumers import.
        .target(
            name: "MarkdownKit",
            dependencies: ["MarkdownPlatformView"]
        ),

        // MARK: - Tests

        .testTarget(
            name: "MarkdownKitTests",
            dependencies: ["MarkdownCore", "MarkdownRenderKit", "MarkdownPlatformView", "MarkdownKit"]
        ),
    ]
)
