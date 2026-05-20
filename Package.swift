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
        .library(name: "MarkdownMath", targets: ["MarkdownMath"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        // MathJaxSwift: locked revision 00e9c3df… is upstream tag v3.5.0 → semver pin.
        .package(url: "https://github.com/colinc86/MathJaxSwift.git", .upToNextMajor(from: "3.5.0")),
        // SwiftDraw: locked revision is a bare `main` commit with no semver tag pointing
        // at it; switching to a version range would change Package.resolved. Pin exactly.
        .package(url: "https://github.com/swhitty/SwiftDraw.git", revision: "4d09d0311f3f116927e7c86b2a9d3d7fe148cc86"),
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

        // MARK: - MarkdownMath

        // MathJax + SwiftDraw implementation of the MathRendering protocol from MarkdownRenderKit.
        .target(
            name: "MarkdownMath",
            dependencies: [
                "MarkdownRenderKit",
                .product(name: "MathJaxSwift", package: "MathJaxSwift"),
                .product(name: "SwiftDraw", package: "SwiftDraw"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "MarkdownKitTests",
            dependencies: ["MarkdownCore", "MarkdownRenderKit", "MarkdownPlatformView", "MarkdownKit"]
        ),
        .testTarget(
            name: "MarkdownMathTests",
            dependencies: ["MarkdownMath", "MarkdownCore", "MarkdownRenderKit", "MarkdownPlatformView"]
        ),
    ]
)
