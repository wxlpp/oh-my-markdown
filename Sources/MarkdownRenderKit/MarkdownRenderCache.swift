import Foundation
import MarkdownCore

/// 有界的正文准备结果缓存。由调用方持有，不保留视图、选区或异步资源。
/// 容量按原文 UTF-8 字节计量，并非平台对象的精确堆内存大小。
@MainActor
public final class MarkdownRenderCache {
    private struct Key: Equatable {
        let source: String
        let options: MarkdownParseOptions
        let width: Double
        let configuration: RenderConfigurationSnapshot
    }

    private struct Entry {
        let key: Key
        let model: RenderDisplayModel
        let sourceBytes: Int
    }

    private let maximumEntryCount: Int
    private let maximumSourceBytes: Int
    private var entries: [Entry] = []
    private var sourceBytes = 0

    public init(maximumEntryCount: Int = 8, maximumSourceBytes: Int = 262_144) {
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumSourceBytes = max(0, maximumSourceBytes)
    }

    public func removeAll() {
        self.entries.removeAll()
        self.sourceBytes = 0
    }

    package func store(_ model: RenderDisplayModel, source: String, options: MarkdownParseOptions, configuration: RenderConfigurationSnapshot) {
        guard self.maximumEntryCount > 0, !source.isEmpty,
              !model.resourceValues.contains(where: { _ in true }) else { return }
        let cost = source.utf8.count
        guard cost <= self.maximumSourceBytes else { return }
        let key = self.key(source: source, options: options, width: model.availableWidth, configuration: configuration)
        if let index = self.entries.firstIndex(where: { $0.key == key }) {
            self.sourceBytes -= self.entries.remove(at: index).sourceBytes
        }
        while !self.entries.isEmpty,
              self.entries.count >= self.maximumEntryCount || self.sourceBytes > self.maximumSourceBytes - cost {
            self.sourceBytes -= self.entries.removeFirst().sourceBytes
        }
        self.entries.append(Entry(key: key, model: model.detachedForReuse(source: source), sourceBytes: cost))
        self.sourceBytes += cost
    }

    package func model(source: String, options: MarkdownParseOptions, width: Double, configuration: RenderConfigurationSnapshot) -> RenderDisplayModel? {
        let key = self.key(source: source, options: options, width: width, configuration: configuration)
        guard let index = self.entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = self.entries.remove(at: index)
        self.entries.append(entry)
        return entry.model
    }

    private func key(source: String, options: MarkdownParseOptions, width: Double, configuration: RenderConfigurationSnapshot) -> Key {
        Key(source: source, options: options, width: width, configuration: RenderConfigurationSnapshot(
            id: .semantic(namespace: "markdown-render-cache", version: 1),
            typography: configuration.typography, colors: configuration.colors,
            spacing: configuration.spacing, generation: 0, mathScale: configuration.mathScale
        ))
    }
}
