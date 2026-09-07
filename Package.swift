// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MarkdownKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
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
        // swift-markdown 是 0.x：`from:` 等价 upToNextMajor（0.x 无特殊处理），会静默吃下
        // 未来每一个 0.x minor。用 upToNextMinor，与下面 SwiftDraw 那条一致——升 minor
        // 时是显式动作。
        .package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.8.0")),
        // MathJaxSwift: locked revision 00e9c3df… is upstream tag v3.5.0 → semver pin.
        .package(url: "https://github.com/colinc86/MathJaxSwift.git", .upToNextMajor(from: "3.5.0")),
        // SwiftDraw: 曾经 pin 在裸 `main` commit `4d09d03` 上，因为当时没有 semver tag
        // 指向它。**那条理由已经过期**——`0.29.0`（2026-07-19）包含该 commit（它领先 16 个
        // commit、behind_by=0），所以换成版本区间不丢任何东西。
        //
        // 必须换掉的原因不是洁癖：**只要本包含有 revision 依赖，它自己就永远无法被下游按
        // 版本引用**。SwiftPM 会直接拒绝解析，报 "package 'markdownkit' is required using
        // a stable-version but 'markdownkit' depends on an unstable-version package
        // 'swiftdraw'"。打了 tag 也没用——这正是 v0.1.0 发出去之后才发现的。
        .package(url: "https://github.com/swhitty/SwiftDraw.git", .upToNextMinor(from: "0.29.0")),
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
            dependencies: ["MarkdownCore", "MarkdownRenderKit", "MarkdownPlatformView", "MarkdownKit"],
            resources: [.copy("Fixtures/RenderGolden")]
        ),
        .testTarget(
            name: "MarkdownMathTests",
            dependencies: ["MarkdownMath", "MarkdownCore", "MarkdownRenderKit", "MarkdownPlatformView"]
        ),
    ]
)
