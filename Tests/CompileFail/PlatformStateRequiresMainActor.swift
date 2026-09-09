#if UMBRELLA_CLIENT
import MarkdownKit
import MarkdownMath
#else
import MarkdownRenderKit
#endif

func inspect(_ snapshot: RenderSnapshot) async {
    await Task.detached {
        #if POSITIVE_ISOLATION
        await MainActor.run { _ = snapshot.attributedString.length }
        #else
        _ = snapshot.attributedString.length
        #endif
    }.value
}

#if UMBRELLA_CLIENT
@MainActor
func umbrellaClientSurface() {
    _ = MarkdownDocument.self
    _ = MarkdownSourceRange.self
    _ = ParsedBlockNode.self
    _ = BlockNode.self
    _ = TableCell.self
    _ = ColumnAlignment.self
    _ = ListItem.self
    _ = InlineNode.self
    _ = MathSpan.self
    _ = MathScanner.self
    _ = MathSentinel.self
    _ = RenderStyle.self
    _ = PlatformFont.self
    _ = PlatformColor.self
    _ = PlatformImage.self
    _ = TableMeasurement.self
    _ = MarkdownSourceHighlighter.self
    _ = SyntaxHighlighter.self
    _ = SyntaxHighlightCache.self
    _ = SyntaxHighlightKind.self
    _ = SyntaxHighlightSpan.self
    _ = SyntaxHighlightKey.self
    _ = PlaceholderMode.self
    _ = RenderedMath.self
    _ = RenderedImage.self
    _ = MathRenderOutcome.self
    _ = MathCacheKey.self
    _ = MathRendering.self
    _ = MathMetrics.self
    _ = RenderedSVG.self
    _ = SVGBlockOutcome.self
    _ = SVGBlockCacheKey.self
    _ = SVGBlockRendering.self
    _ = SVGViewBoxParser.self
    _ = ColorToken.self
    _ = ColorTokens.self
    _ = MarkdownTextRole.self
    _ = TypographyTokens.self
    _ = SpacingTokens.self
    _ = MarkdownConfigurationID.self
    _ = RenderConfigurationSnapshot.self
    _ = MarkdownRenderConfiguration.self
    _ = RenderInput.self
    _ = RenderDisplayModel.self
    _ = ResourceID.self
    _ = UnresolvedResource.self
    _ = DisplayRun.self
    _ = DisplayBlock.self
    _ = AccessibilityRole.self
    _ = AccessibilityNodeID.self
    _ = AccessibilityActivation.self
    _ = AccessibilityTree.self
    _ = AccessibilityNode.self
    _ = RenderSnapshot.self
    _ = RenderPreparer.self
    _ = MathRendererConfiguration.self
    _ = SVGRendererConfiguration.self
    _ = MarkdownLabelView.self
    _ = MarkdownEditorTextView.self
    _ = MarkdownEditorSelection.self
    _ = MarkdownEditorOptions.self
    _ = MarkdownEditorEditResult.self
    _ = MarkdownEditorInputAction.self
    _ = MarkdownEditorCommands.self
    _ = MarkdownDocument(parsing: "client")
    // README UIKit/AppKit example: the supported rendering and editing boundaries.
    let view = MarkdownLabelView()
    view.renderStyle = .default
    view.setMarkdown("# Hello, **World**!")
    let editor = MarkdownEditorTextView()
    editor.renderStyle = .default
    editor.setMarkdown("# Draft\n\n- [ ] Ship the editor")
    _ = MarkdownText("$x$").mathRenderer(MathRendererConfiguration(renderer: MathJaxRenderer()))
    _ = MarkdownRenderConfiguration.default.snapshot(generation: 0)
}
#endif
