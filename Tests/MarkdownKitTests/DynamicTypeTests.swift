import Foundation
@testable import MarkdownPlatformView
@testable import MarkdownRenderKit
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Task 11's typography contract. A reader who has turned text size up expects
/// the document to follow; a host that set an exact font expects it not to.
@MainActor
@Suite(.serialized)
struct DynamicTypeTests {
    private static let ascending: [MarkdownContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    private func sizes(_ category: MarkdownContentSizeCategory, role: MarkdownTextRole) -> Double {
        RenderStyle.default
            .snapshot(generation: 0, contentSizeCategory: category)
            .typography.pointSizes[role] ?? 0
    }

    @Test(arguments: [
        MarkdownTextRole.body, .code, .heading(level: 1), .heading(level: 3), .heading(level: 6),
    ])
    func defaultMetricsGrowMonotonicallyWithTheCategory(role: MarkdownTextRole) throws {
        let sizes = Self.ascending.map { self.sizes($0, role: role) }
        #expect(sizes.allSatisfy { $0 > 0 })
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 <= $1 }, "\(role) is not monotonic: \(sizes)")
        let first = try #require(sizes.first)
        let last = try #require(sizes.last)
        #expect(last > first, "\(role) never grows: \(sizes)")
    }

    /// The accessibility categories are the point of the feature: a reader who
    /// enables them must get a materially larger document, not a rounding.
    @Test func accessibilityCategoriesAreMateriallyLargerThanLarge() {
        let base = self.sizes(.large, role: .body)
        #expect(self.sizes(.accessibilityMedium, role: .body) > base * 1.2)
        #expect(self.sizes(.accessibilityExtraExtraExtraLarge, role: .body) > base * 1.8)
    }

    /// Headings must stay above body text at every size, or the hierarchy the
    /// reader relies on inverts at large categories.
    @Test(arguments: [
        MarkdownContentSizeCategory.large, .accessibilityLarge, .accessibilityExtraExtraExtraLarge,
    ])
    func headingsStayLargerThanBody(category: MarkdownContentSizeCategory) {
        let body = self.sizes(category, role: .body)
        for level in 1 ... 3 {
            #expect(self.sizes(category, role: .heading(level: level)) > body, "h\(level) collapsed into body at \(category)")
        }
        // And ordered among themselves.
        let headings = (1 ... 6).map { self.sizes(category, role: .heading(level: $0)) }
        #expect(zip(headings, headings.dropFirst()).allSatisfy { $0 >= $1 }, "heading order inverted: \(headings)")
    }

    /// Ordering alone is not hierarchy: on iOS each heading follows its own text
    /// style's curve, which damps where `.body`'s does not, and the default h2
    /// fell to 1.07x body at the maximum category while h4 fell below it. The
    /// floor is `min(ratio, sqrt(ratio))` — the square root where a heading is
    /// larger than body, the ratio itself where it is smaller, so h5 and h6 are
    /// not pushed up.
    ///
    /// Inert on macOS by construction: AppKit has no per-style metrics table, so
    /// every role scales by the same factor and the declared ratios hold exactly.
    /// The iOS run in `ios18-dynamic-type` is what enforces this.
    @Test(arguments: MarkdownContentSizeCategory.allCases)
    func headingsNeverFallBelowTheirDampedDeclaredRatio(category: MarkdownContentSizeCategory) {
        let declaredBody = self.sizes(.large, role: .body)
        let body = self.sizes(category, role: .body)
        for level in 1 ... 6 {
            let role = MarkdownTextRole.heading(level: level)
            let ratio = self.sizes(.large, role: role) / declaredBody
            let floor = body * min(ratio, ratio.squareRoot())
            let resolved = self.sizes(category, role: role)
            #expect(resolved >= floor - 0.001, "h\(level) is \(resolved) at \(category), under its floor of \(floor)")
        }
    }

    /// Opting out is detected from the stored size, so a font assigned at exactly
    /// the registered size is indistinguishable from the registered one and keeps
    /// scaling. `pinFont(for:)` is how a host says it meant that size.
    @Test func aCustomFontAtTheRegisteredSizeIsPinnedOnRequest() {
        var scaling = RenderStyle.default
        // The registered size, not a literal: it differs between the platforms.
        let size = scaling.bodyFont.pointSize
        scaling.bodyFont = .systemFont(ofSize: size, weight: .bold)
        #expect(self.body(of: scaling, at: .accessibilityExtraExtraExtraLarge) > Double(size))
        var pinned = scaling
        pinned.pinFont(for: .body)
        #expect(self.body(of: pinned, at: .extraSmall) == Double(size))
        #expect(self.body(of: pinned, at: .accessibilityExtraExtraExtraLarge) == Double(size))
    }

    private func body(of style: RenderStyle, at category: MarkdownContentSizeCategory) -> Double {
        style.snapshot(generation: 0, contentSizeCategory: category).typography.pointSizes[.body] ?? 0
    }

    /// The wrapper is a host-facing opt-in, not only a resolution helper: handing
    /// one to the style has to leave the role following the reader.
    @Test func aScaledFontAssignedToARoleFollowsTheCategory() {
        var style = RenderStyle.fixedDefault
        style.setFont(MarkdownScaledFont(base: .systemFont(ofSize: 19, weight: .medium), relativeTo: .body), for: .body)
        #expect(self.body(of: style, at: .extraSmall) < 19)
        #expect(self.body(of: style, at: .accessibilityExtraExtraExtraLarge) > 19)
    }

    /// A host that set an exact font is documenting an exact size. It must not
    /// move under the reader's setting unless the host asks for that.
    @Test func aFixedCustomFontDoesNotScale() {
        var style = RenderStyle.default
        style.bodyFont = .systemFont(ofSize: 19, weight: .medium)
        let small = style.snapshot(generation: 0, contentSizeCategory: .extraSmall)
        let huge = style.snapshot(generation: 0, contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(small.typography.pointSizes[.body] == 19)
        #expect(huge.typography.pointSizes[.body] == 19)
    }

    /// …and opts in by wrapping, which keeps its own face and weight.
    @Test func aScaledCustomFontFollowsTheCategory() {
        let scaled = MarkdownScaledFont(base: .systemFont(ofSize: 19, weight: .medium), relativeTo: .body)
        let small = scaled.resolve(contentSizeCategory: .extraSmall)
        let huge = scaled.resolve(contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(huge.pointSize > small.pointSize)
        #expect(small.pointSize > 0)
        #expect(huge.fontDescriptor.symbolicTraits == scaled.resolve(contentSizeCategory: .large).fontDescriptor.symbolicTraits)
    }

    /// Spacing and chrome come from the same category as the text, or the
    /// document grows without its layout following.
    @Test func spacingAndChromeScaleWithTheText() {
        let small = RenderStyle.default.snapshot(generation: 0, contentSizeCategory: .large)
        let huge = RenderStyle.default.snapshot(generation: 0, contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(huge.spacing.paragraph > small.spacing.paragraph)
        #expect(huge.spacing.codeInsets > small.spacing.codeInsets)
        #expect(huge.spacing.quoteIndent >= small.spacing.quoteIndent)
    }

    /// The category is part of what a snapshot *is*, so a change to it has to be
    /// a different configuration — otherwise a cached render is reused at the
    /// wrong size.
    @Test func theCategoryParticipatesInConfigurationIdentity() throws {
        let large = MarkdownRenderConfiguration.default(contentSizeCategory: .large)
        let huge = MarkdownRenderConfiguration.default(contentSizeCategory: .accessibilityLarge)
        #expect(large.configurationID != huge.configurationID)
        #expect(large.configurationID == MarkdownRenderConfiguration.default(contentSizeCategory: .large).configurationID)
        let largeBody = try #require(large.snapshot(generation: 0).typography.pointSizes[.body])
        let hugeBody = try #require(huge.snapshot(generation: 0).typography.pointSizes[.body])
        #expect(largeBody < hugeBody)
    }

    /// A host style keeps the identity the host gave it, so a size change has to
    /// arrive as a new generation rather than a new id.
    @Test func aHostStyleKeepsItsIdentityAndStillResolvesAtTheCategory() throws {
        let id = MarkdownConfigurationID.semantic(namespace: "host-style", version: 1)
        var style = RenderStyle.fixedDefault
        style.scaleFontWithContentSize(for: .body)
        let large = MarkdownRenderConfiguration(style: style, configurationID: id, contentSizeCategory: .large)
        let huge = MarkdownRenderConfiguration(style: style, configurationID: id, contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        #expect(large.configurationID == huge.configurationID)
        let largeBody = try #require(large.snapshot(generation: 0).typography.pointSizes[.body])
        let hugeBody = try #require(huge.snapshot(generation: 1).typography.pointSizes[.body])
        #expect(largeBody < hugeBody)
    }
}
