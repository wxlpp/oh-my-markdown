/// A single item within a Markdown list.
public struct ListItem: Sendable, Equatable {
    /// Checked / unchecked state for GFM task-list items.
    public enum Checkbox: Sendable, Equatable {
        case checked
        case unchecked
    }

    public init(blocks: [BlockNode], checkbox: Checkbox? = nil) {
        self.blocks = blocks
        self.checkbox = checkbox
    }

    /// The block-level content of this item (usually one paragraph, but
    /// loose lists may contain multiple blocks).
    public let blocks: [BlockNode]

    /// GFM task-list checkbox state, or `nil` for a regular item.
    public let checkbox: Checkbox?
}
