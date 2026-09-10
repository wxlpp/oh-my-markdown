import CryptoKit
import Foundation

/// Full measured contents of an overflow table, owned alongside its main-flow reservation.
/// Retains cell resource owners even while a platform overlay outlives a snapshot swap.
@MainActor
package final class RenderTableOverlay {
    package let attributedString: NSAttributedString
    package let naturalWidth: CGFloat
    package let height: CGFloat
    package let style: RenderStyle
    private let resourceOwners: [any ResourceResidencyOwner]

    package init(attributedString: NSAttributedString, naturalWidth: CGFloat, height: CGFloat, style: RenderStyle, resourceOwners: [any ResourceResidencyOwner]) {
        self.attributedString = NSAttributedString(attributedString: attributedString)
        self.naturalWidth = naturalWidth
        self.height = height
        self.style = style
        self.resourceOwners = resourceOwners
    }
}

@MainActor
public final class RenderSnapshot {
    /// Identity for snapshot-replacement transactions and residency diagnostics.
    package let id: UUID
    private var flattened: NSAttributedString?
    package private(set) var fullStringAssemblyCount = 0
    /// Compatibility facade. Incremental installation consumes `edit`, so it
    /// never needs to concatenate the unchanged document on the hot path.
    public var attributedString: NSAttributedString {
        if let flattened { return flattened }
        self.fullStringAssemblyCount += 1
        let result = NSMutableAttributedString(string: "")
        for chunk in self.chunks {
            result.append(chunk.text)
        }
        let value = NSAttributedString(attributedString: result)
        self.flattened = value
        return value
    }

    package let chunks: [MaterializedBlock]
    package let configuration: RenderConfigurationSnapshot?
    package let edit: MaterializedEdit?
    private var renderedIdentity: String?
    public var renderedContentID: String {
        if let renderedIdentity { return renderedIdentity }
        let digests = self.chunks.isEmpty ? [renderedTextDigest(self.flattened?.string ?? "")] : self.chunks.map(\.textDigest)
        let value = renderedDigest(digests)
        self.renderedIdentity = value
        return value
    }

    public let materializationWork: MarkdownMaterializationWork
    package let renderedLength: Int
    public let displayModel: RenderDisplayModel
    package let resourceOwners: [any ResourceResidencyOwner]
    package let blockStarts: [Int]
    package let tableOverlays: [Int: RenderTableOverlay]

    package init(
        id: UUID = UUID(), attributedString: NSAttributedString, displayModel: RenderDisplayModel,
        resourceOwners: [any ResourceResidencyOwner], blockStarts: [Int] = [], tableOverlays: [Int: RenderTableOverlay] = [:]
    ) {
        self.id = id
        self.flattened = NSAttributedString(attributedString: attributedString)
        self.chunks = []
        self.configuration = nil
        self.edit = nil
        self.materializationWork = MarkdownMaterializationWork(materializedBlocks: 0, reusedBlocks: 0, materializedUTF16: attributedString.length, fallbackReason: .unprepared)
        self.renderedLength = attributedString.length
        self.displayModel = displayModel
        self.resourceOwners = resourceOwners
        self.blockStarts = blockStarts
        self.tableOverlays = tableOverlays
    }

    package init(id: UUID, displayModel: RenderDisplayModel, chunks: [MaterializedBlock], configuration: RenderConfigurationSnapshot, edit: MaterializedEdit?, work: MarkdownMaterializationWork) {
        self.id = id
        self.displayModel = displayModel
        self.chunks = chunks
        self.configuration = configuration
        self.edit = edit
        self.materializationWork = work
        self.flattened = nil
        var offset = 0
        var starts: [Int] = []
        var owners: [any ResourceResidencyOwner] = []
        var overlays: [Int: RenderTableOverlay] = [:]
        for (index, chunk) in chunks.enumerated() {
            starts.append(offset + chunk.contentStart)
            offset += chunk.text.length
            owners += chunk.owners
            if let overlay = chunk.overlay { overlays[index] = overlay }
        }
        self.blockStarts = starts
        self.renderedLength = offset
        self.resourceOwners = owners
        self.tableOverlays = overlays
    }
}

/// Platform work counters exclude parsing/preparation. Metadata still scales
/// with block count; materializedUTF16 counts only newly created rich text.
public struct MarkdownMaterializationWork: Sendable, Equatable {
    public let materializedBlocks: Int
    public let reusedBlocks: Int
    public let materializedUTF16: Int
    public let fallbackReason: MarkdownMaterializationFallback?
}

public enum MarkdownMaterializationFallback: String, Sendable {
    case initial, unprepared, missingDelta, baselineMismatch, configurationChanged
    case resources, shiftedSuffix, invalidRange
}

@MainActor
package final class MaterializedBlock {
    package let text: NSAttributedString
    private var digestStorage: Data?
    package var textDigest: Data {
        if let digestStorage { return digestStorage }
        let digest = renderedTextDigest(self.text.string)
        self.digestStorage = digest
        return digest
    }

    package let contentStart: Int
    package let owners: [any ResourceResidencyOwner]
    package let overlay: RenderTableOverlay?
    package init(text: NSAttributedString, contentStart: Int, owners: [any ResourceResidencyOwner], overlay: RenderTableOverlay?) {
        self.text = NSAttributedString(attributedString: text)
        self.contentStart = contentStart
        self.owners = owners
        self.overlay = overlay
    }
}

@MainActor
package struct MaterializedEdit {
    package let baselineSnapshotID: UUID
    package let range: NSRange
    package let replacement: NSAttributedString
}

/// Stable block-composed identity. Hash each changed UTF-16 block once; combine
/// fixed-size digests without flattening the unchanged rendered document.
private func renderedTextDigest(_ text: String) -> Data {
    // Every Swift String has a lossless UTF-16 representation. Foundation's
    // bulk conversion avoids per-code-unit append overhead in debug builds.
    let bytes = text.data(using: .utf16LittleEndian)!
    return Data(SHA256.hash(data: bytes))
}

private func renderedDigest(_ blocks: [Data]) -> String {
    var hash = SHA256()
    hash.update(data: Data("OhMyMarkdown.rendered.v1".utf8))
    for block in blocks {
        hash.update(data: block)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
