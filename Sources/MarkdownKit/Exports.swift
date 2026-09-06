public import MarkdownCore
public import MarkdownPlatformView
public import MarkdownRenderKit

// Access-level imports do not re-export names (SE-0409). Explicit aliases
// preserve the umbrella API while avoiding underscored compiler attributes.
public typealias MarkdownDocument = MarkdownCore.MarkdownDocument
public typealias MarkdownSourceRange = MarkdownCore.MarkdownSourceRange
public typealias ParsedBlockNode = MarkdownCore.ParsedBlockNode
public typealias BlockNode = MarkdownCore.BlockNode
public typealias TableCell = MarkdownCore.TableCell
public typealias ColumnAlignment = MarkdownCore.ColumnAlignment
public typealias ListItem = MarkdownCore.ListItem
public typealias InlineNode = MarkdownCore.InlineNode
public typealias MathSpan = MarkdownCore.MathSpan
public typealias MathScanner = MarkdownCore.MathScanner
public typealias MathSentinel = MarkdownCore.MathSentinel

public typealias RenderStyle = MarkdownRenderKit.RenderStyle
public typealias PlatformFont = MarkdownRenderKit.PlatformFont
public typealias PlatformColor = MarkdownRenderKit.PlatformColor
public typealias PlatformImage = MarkdownRenderKit.PlatformImage
public typealias AttributedStringRenderer = MarkdownRenderKit.AttributedStringRenderer
public typealias TableMeasurement = MarkdownRenderKit.TableMeasurement
public typealias MarkdownSourceHighlighter = MarkdownRenderKit.MarkdownSourceHighlighter
public typealias SyntaxHighlighter = MarkdownRenderKit.SyntaxHighlighter
public typealias PlaceholderMode = MarkdownRenderKit.PlaceholderMode
public typealias MathRenderedGlyph = MarkdownRenderKit.MathRenderedGlyph
public typealias MathRenderOutcome = MarkdownRenderKit.MathRenderOutcome
public typealias MathCacheKey = MarkdownRenderKit.MathCacheKey
public typealias MathRendering = MarkdownRenderKit.MathRendering
public typealias MathMetrics = MarkdownRenderKit.MathMetrics
public typealias SVGBlockGlyph = MarkdownRenderKit.SVGBlockGlyph
public typealias SVGBlockOutcome = MarkdownRenderKit.SVGBlockOutcome
public typealias SVGBlockCacheKey = MarkdownRenderKit.SVGBlockCacheKey
public typealias SVGBlockRendering = MarkdownRenderKit.SVGBlockRendering
public typealias SVGViewBoxParser = MarkdownRenderKit.SVGViewBoxParser
public typealias ColorToken = MarkdownRenderKit.ColorToken
public typealias ColorTokens = MarkdownRenderKit.ColorTokens
public typealias MarkdownTextRole = MarkdownRenderKit.MarkdownTextRole
public typealias TypographyTokens = MarkdownRenderKit.TypographyTokens
public typealias SpacingTokens = MarkdownRenderKit.SpacingTokens
public typealias MarkdownConfigurationID = MarkdownRenderKit.MarkdownConfigurationID
public typealias RenderConfigurationSnapshot = MarkdownRenderKit.RenderConfigurationSnapshot
public typealias MarkdownRenderConfiguration = MarkdownRenderKit.MarkdownRenderConfiguration
public typealias RenderInput = MarkdownRenderKit.RenderInput
public typealias RenderDisplayModel = MarkdownRenderKit.RenderDisplayModel
public typealias ResourceID = MarkdownRenderKit.ResourceID
public typealias UnresolvedResource = MarkdownRenderKit.UnresolvedResource
public typealias DisplayRun = MarkdownRenderKit.DisplayRun
public typealias DisplayBlock = MarkdownRenderKit.DisplayBlock
public typealias AccessibilityRole = MarkdownRenderKit.AccessibilityRole
public typealias AccessibilityNodeID = MarkdownRenderKit.AccessibilityNodeID
public typealias AccessibilityActivation = MarkdownRenderKit.AccessibilityActivation
public typealias AccessibilityTree = MarkdownRenderKit.AccessibilityTree
public typealias AccessibilityNode = MarkdownRenderKit.AccessibilityNode
public typealias RenderSnapshot = MarkdownRenderKit.RenderSnapshot
public typealias RenderPreparer = MarkdownRenderKit.RenderPreparer
public typealias MathRendererConfiguration = MarkdownRenderKit.MathRendererConfiguration
public typealias SVGRendererConfiguration = MarkdownRenderKit.SVGRendererConfiguration

public typealias MarkdownLabelView = MarkdownPlatformView.MarkdownLabelView
public typealias MarkdownEditorTextView = MarkdownPlatformView.MarkdownEditorTextView
public typealias MarkdownEditorSelection = MarkdownPlatformView.MarkdownEditorSelection
public typealias MarkdownEditorOptions = MarkdownPlatformView.MarkdownEditorOptions
public typealias MarkdownEditorEditResult = MarkdownPlatformView.MarkdownEditorEditResult
public typealias MarkdownEditorInputAction = MarkdownPlatformView.MarkdownEditorInputAction
public typealias MarkdownEditorCommands = MarkdownPlatformView.MarkdownEditorCommands
public typealias MathLoadCoordinator = MarkdownPlatformView.MathLoadCoordinator
public typealias SVGBlockLoadCoordinator = MarkdownPlatformView.SVGBlockLoadCoordinator
