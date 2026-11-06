import OhMyMarkdown
import Testing

@MainActor struct RenderCacheConsumerTests {
    @Test func umbrellaExportsCacheAndModifiers() {
        let cache = MarkdownRenderCache(maximumEntryCount: 2, maximumSourceBytes: 1024)
        _ = MarkdownText("Hello").markdownRenderCache(cache)
        _ = MarkdownStreamingText(MarkdownStreamingSource("Hello")).markdownRenderCache(nil)
        cache.removeAll()
    }
}
