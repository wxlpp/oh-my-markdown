import MarkdownCore

public struct RenderInput: Sendable {
  public let document: MarkdownDocument
  public let source: String?
  public let availableWidth: Double
  public let configuration: RenderConfigurationSnapshot
  public let placeholderMode: PlaceholderMode

  public init(
    document: MarkdownDocument, source: String?, availableWidth: Double,
    configuration: RenderConfigurationSnapshot, placeholderMode: PlaceholderMode
  ) {
    self.document = document
    self.source = source
    self.availableWidth = availableWidth
    self.configuration = configuration
    self.placeholderMode = placeholderMode
  }
}
