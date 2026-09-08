import MarkdownCore

public struct RenderInput: Sendable {
    public let document: MarkdownDocument
    public let source: String?
    public let availableWidth: Double
    public let configuration: RenderConfigurationSnapshot
    public let placeholderMode: PlaceholderMode
    /// Identity anchor for the accessibility tree: it changes when the document
    /// is replaced and not when the layout is.
    package let documentGeneration: UInt64
    package let previousModel: RenderDisplayModel?
    package let sourceBuffer: IncrementalSourceBuffer?
    package let attemptRecorder: ParseAttemptRecorder?

    public init(
        document: MarkdownDocument, source: String?, availableWidth: Double,
        configuration: RenderConfigurationSnapshot, placeholderMode: PlaceholderMode
    ) {
        self.document = document
        self.source = source
        self.availableWidth = availableWidth
        self.configuration = configuration
        self.placeholderMode = placeholderMode
        self.documentGeneration = 0
        self.previousModel = nil
        self.sourceBuffer = nil
        self.attemptRecorder = nil
    }

    package init(
        document: MarkdownDocument,
        source: String?,
        availableWidth: Double,
        configuration: RenderConfigurationSnapshot,
        placeholderMode: PlaceholderMode,
        documentGeneration: UInt64 = 0,
        previousModel: RenderDisplayModel?,
        sourceBuffer: IncrementalSourceBuffer? = nil,
        attemptRecorder: ParseAttemptRecorder? = nil
    ) {
        self.document = document
        self.source = source
        self.availableWidth = availableWidth
        self.configuration = configuration
        self.placeholderMode = placeholderMode
        self.documentGeneration = documentGeneration
        self.previousModel = previousModel
        self.sourceBuffer = sourceBuffer
        self.attemptRecorder = attemptRecorder
    }
}
