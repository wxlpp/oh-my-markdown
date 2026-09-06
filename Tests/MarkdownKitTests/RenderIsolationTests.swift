import CoreGraphics
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRenderKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

@Suite
struct RenderIsolationTests {
  @Test @MainActor func preparationCrossesDetachedBoundary() async throws {
    let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 3)
    let source =
      "# Title\n\nHello `code` ![alt](https://example.com/a.png) $x$\n\n```svg\n<svg/>\n```"
    let input = RenderInput(
      document: MarkdownDocument(parsing: source), source: source, availableWidth: 300,
      configuration: configuration, placeholderMode: .streaming)
    let model = try await Task.detached {
      try RenderPreparer(configuration: configuration).prepare(input)
    }.value
    let transported = await Task.detached { model }.value
    #expect(transported == model)
    #expect(model.blocks.count == 3)
    #expect(model.runs.first?.text == "Title")
    #expect(model.runs.first?.role == .heading(level: 1))
    #expect(model.runs.contains { $0.text == "code" && $0.role == .code })
    #expect(model.resources.count == 3)
    #expect(Set(model.runs.compactMap(\.resourceID)).count == 3)
    #expect(model.blocks.first?.sourceRange == input.document.parsedBlocks.first?.sourceRange)
    let snapshot = RenderMaterializer(configuration: configuration).materialize(
      model, resources: ResolvedResourceSnapshot(values: [:]))
    #expect(snapshot.attributedString.string.contains("Hello code"))
    #expect(snapshot.displayModel == model)
    #expect(snapshot.attributedString.attribute(.font, at: 0, effectiveRange: nil) != nil)
  }

  @Test @MainActor func snapshotOwnsImmutableAttributedContent() {
    let mutable = NSMutableAttributedString(string: "original")
    let model = RenderDisplayModel(
      runs: [], blocks: [], resources: [], accessibility: AccessibilityTree(roots: []))
    let snapshot = RenderSnapshot(
      attributedString: mutable, displayModel: model, resourceOwners: [])
    mutable.mutableString.setString("changed")
    #expect(snapshot.attributedString.string == "original")
  }

  @Test func imageBackingReadsAreIndependentAndConcurrent() async throws {
    let context = try #require(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let backing = try ImmutableCGImageBacking(frames: [#require(context.makeImage())])
    context.clear(CGRect(x: 0, y: 0, width: 2, height: 2))
    #expect(backing.accountedPixelBytes == 16)
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<32 {
        group.addTask {
          guard let data = backing.frames[0].dataProvider?.data else { return false }
          let bytes = CFDataGetBytePtr(data)!
          return backing.frames[0].width == 2 && bytes[0] == 255 && bytes[3] == 255
        }
      }
      for await valid in group { #expect(valid) }
    }
  }

  @Test @MainActor func materializationRetainsResourceOwnerAndPointGeometry() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let backing = try ImmutableCGImageBacking(frames: [#require(context.makeImage())])
    let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
    let materializer = RenderMaterializer(configuration: configuration)
    #expect(materializer.platformImage(from: backing, scale: 0) == nil)
    #expect(materializer.platformImage(from: backing, frame: 1) == nil)
    let image = try #require(materializer.platformImage(from: backing, scale: 2))
    let id = ResourceID(rawValue: "math")
    let model = RenderDisplayModel(
      runs: [DisplayRun(text: "x", role: .body, resourceID: id)], blocks: [],
      resources: [.math(id: id, latex: "x", display: false)],
      accessibility: AccessibilityTree(roots: []))
    weak var observedOwner: LegacyResourceOwner?
    var snapshot: RenderSnapshot?
    do {
      let owner = LegacyResourceOwner(retaining: NSObject())
      observedOwner = owner
      snapshot = materializer.materialize(
        model,
        resources: ResolvedResourceSnapshot(values: [
          id: .math(image: image, baselineOffset: -2, owner: owner)
        ]))
    }
    #expect(observedOwner != nil)
    #expect(snapshot?.attributedString.string == "\u{FFFC}")
    let attachment = try #require(
      snapshot?.attributedString.attribute(.attachment, at: 0, effectiveRange: nil)
        as? NSTextAttachment)
    #expect(attachment.bounds == CGRect(x: 0, y: -2, width: 2, height: 1))
    snapshot = nil
    #expect(observedOwner == nil)
  }

  @Test @MainActor func staticResourcesKeepIdentityAndPreparationChecksConfiguration() throws {
    let configuration = MarkdownRenderConfiguration.default.snapshot(generation: 0)
    let document = MarkdownDocument(parsing: "![alt](image.png)")
    let input = RenderInput(
      document: document, source: nil, availableWidth: 100, configuration: configuration,
      placeholderMode: .static)
    let model = try RenderPreparer(configuration: configuration).prepare(input)
    #expect(model.runs.first?.text == "\u{FFFC}")
    #expect(model.runs.first?.resourceID != nil)
    #expect(model == (try RenderPreparer(configuration: configuration).prepare(input)))
    let other = MarkdownRenderConfiguration.default.snapshot(generation: 1)
    #expect(throws: RenderPreparer.PreparationError.configurationMismatch) {
      try RenderPreparer(configuration: other).prepare(input)
    }
  }
}
