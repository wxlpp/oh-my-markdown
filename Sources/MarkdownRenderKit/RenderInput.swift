import MarkdownCore

public struct RenderInput: Sendable {
    public let document: MarkdownDocument
    public let source: String?
    public let availableWidth: Double
    public let configuration: RenderConfigurationSnapshot
    public let placeholderMode: PlaceholderMode
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
        previousModel: RenderDisplayModel?,
        sourceBuffer: IncrementalSourceBuffer? = nil,
        attemptRecorder: ParseAttemptRecorder? = nil
    ) {
        self.document = document
        self.source = source
        self.availableWidth = availableWidth
        self.configuration = configuration
        self.placeholderMode = placeholderMode
        self.previousModel = previousModel
        self.sourceBuffer = sourceBuffer
        self.attemptRecorder = attemptRecorder
    }
}
