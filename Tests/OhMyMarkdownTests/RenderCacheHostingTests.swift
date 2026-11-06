@testable import MarkdownPlatformView
import OhMyMarkdown
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct RenderCacheHostingTests {
    @Test(arguments: [false, true])
    func rebuiltSwiftUIBodyHasTextDuringFirstLayout(streaming: Bool) async throws {
        let cache = MarkdownRenderCache()
        let source = "Completed **body**\n\nSecond paragraph."
        let stream = MarkdownStreamingSource(source)
        func content(visible: Bool) -> some View {
            Group {
                if visible {
                    if streaming { MarkdownStreamingText(stream) }
                    else { MarkdownText(source) }
                }
            }.markdownRenderCache(cache).frame(width: 320)
        }
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content(visible: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func layout() {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        }
        #else
        let host = NSHostingView(rootView: content(visible: true))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        func layout() {
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
        }
        #endif
        layout()
        let old = try #require(await settleForLabel(in: host))
        await old.settled { old.currentSnapshot?.displayModel.availableWidth == 320 }
        let text = try #require(old.currentSnapshot?.attributedString.string)
        host.rootView = content(visible: false)
        layout()
        await old.settled { old.currentSnapshot == nil }
        host.rootView = content(visible: true)
        layout()
        // No async turn between construction and these first-frame assertions.
        let fresh = try #require(firstLabel(in: host))
        #expect(fresh !== old)
        #expect(fresh.currentSnapshot?.attributedString.string == text)
        #expect(fresh.currentCommitToken?.sequence == 0)
        withExtendedLifetime(host) {}
    }
}
