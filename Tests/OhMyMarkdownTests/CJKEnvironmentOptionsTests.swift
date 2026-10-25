@testable import MarkdownPlatformView
import OhMyMarkdown
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor @Suite(.timeLimit(.minutes(2)), .serialized)
struct CJKEnvironmentOptionsTests {
    @Test(arguments: [false, true])
    func unchangedSourceReparsesWhenEnvironmentChanges(streaming: Bool) async throws {
        let source = "中**“文”**后"
        let stream = MarkdownStreamingSource(source)
        func content(_ options: MarkdownParseOptions) -> some View {
            Group {
                if streaming { MarkdownStreamingText(stream) }
                else { MarkdownText(source) }
            }.markdownParseOptions(options)
        }
        #if canImport(UIKit)
        let host = UIHostingController(rootView: content([]))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: content([]))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        #endif
        let label = try #require(await settleForLabel(in: host))
        await label.settled { label.currentSnapshot?.attributedString.string == source }
        for options: MarkdownParseOptions in [.cjkFriendlyEmphasis, []] {
            host.rootView = content(options)
            #if canImport(UIKit)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            #else
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            #endif
            let expected = options.isEmpty ? source : "中“文”后"
            await label.settled { label.currentSnapshot?.attributedString.string == expected }
            #expect(label.parseOptions == options)
        }
        if streaming {
            stream.append("续")
            await label.settled { label.currentSnapshot?.attributedString.string == source + "续" }
        }
        withExtendedLifetime(host) {}
    }
}
