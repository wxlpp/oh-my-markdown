# MarkdownKit

A lightweight Markdown rendering and source editing library for iOS and macOS, built with **TextKit 2** and [swift-markdown](https://github.com/swiftlang/swift-markdown).

## ✨ Features

- 🚀 **TextKit 2** based rendering for optimal performance
- 📝 Full CommonMark support via swift-markdown
- 🖼️ **Image Loading** - Async image loading with caching and placeholder support
- ✨ Rich visual rendering for headings, quotes, code blocks, and tables
- ✍️ Native Markdown source editor backed by `UITextView` / `NSTextView`
- 🎨 Customizable rendering through `RenderStyle`
- 📱 Native SwiftUI integration
- 🖥️ Native UIKit and AppKit views
- 🌐 Perfect Chinese/CJK text support
- ⚡️ Incremental streaming updates for chat-like output

## 📋 Requirements

- iOS 26.0+
- Xcode 17.0+
- Swift 6.2+

## 📦 Installation

### Swift Package Manager

Add MarkdownKit to your project using Swift Package Manager:

1. In Xcode: **File** → **Add Package Dependencies...**
2. Enter the repository URL: `https://github.com/wxlpp/MarkdownKit.git`
3. Select the version you want to use

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wxlpp/MarkdownKit.git", .upToNextMinor(from: "0.1.2"))
]
```

## 🚀 Usage

### SwiftUI

```swift
import SwiftUI
import MarkdownKit

struct ContentView: View {
    var body: some View {
        MarkdownText("""
        # Hello, World!
        
        This is **bold** and this is *italic*.
        
        - Item 1
        - Item 2
        - Item 3
        """)
    }
}
```

### SwiftUI Editor

```swift
import SwiftUI
import MarkdownKit

struct EditorView: View {
    @State private var source = "# Hello\n\n- [ ] Edit me"

    var body: some View {
        MarkdownEditor(text: $source)
            .markdownStyle(.default)
    }
}
```

`MarkdownEditor` is a source editor, not a WYSIWYG surface. The bound `String` remains the single source of truth; the attributed text inside the native text view is derived state used only for highlighting and editor presentation.

### Custom Style

```swift
var style = RenderStyle.default
style.paragraphSpacing = 16
style.quoteIndent = 20

#if canImport(UIKit)
style.bodyFont = .preferredFont(forTextStyle: .body)
style.codeBackgroundColor = .secondarySystemBackground
#endif

MarkdownText(markdownText)
    .markdownStyle(style)
```

### Streaming Output

```swift
import SwiftUI
import MarkdownKit

struct ChatView: View {
    @State private var markdown = MarkdownStreamingSource()

    var body: some View {
        ScrollView {
            MarkdownStreamingText(markdown)
                .padding()
        }
        .task {
            for await chunk in stream {
                await MainActor.run {
                    markdown.append(chunk)
                }
            }
        }
    }
}
```

### UIKit / AppKit

```swift
let view = MarkdownLabelView()
view.renderStyle = .default
view.setMarkdown("# Hello, **World**!")

let editor = MarkdownEditorTextView()
editor.renderStyle = .default
editor.setMarkdown("# Draft\n\n- [ ] Ship the editor")
```

### Parsing Only

```swift
let document = MarkdownDocument(parsing: "# Title\n\nHello")
print(document.blocks)
```

### Rendering Only

```swift
let document = MarkdownDocument(parsing: "| A | B |\n|:-:|--:|\n| 1 | 2 |")
let renderer = AttributedStringRenderer(style: .default, availableWidth: 320)
let attributedString = renderer.render(document.blocks)
```

### Math (LaTeX)

LaTeX math is an opt-in feature provided by the separate **MarkdownMath** product. Attach a renderer with the `.mathRenderer(_:)` modifier:

```swift
import MarkdownKit
import MarkdownMath

MarkdownText("Euler: $e^{i\\pi}+1=0$")
    .mathRenderer(MathRendererConfiguration(renderer: MathJaxRenderer()))
```

Notes:

Custom renderer wrappers are unique by default; only an explicit semantic configuration ID opts them into sharing completed results (never in-flight tasks).

- Without `.mathRenderer(_:)`, math is gracefully degraded and shown as its raw LaTeX text.
- `MarkdownEditor` only token-highlights the math delimiters; it does not render formulas.
- `MathJaxRenderer` loads a minimal core package set (`base` + `ams`, plus `noundefined` so undefined commands render as a visible error placeholder rather than failing). Non-core commands such as `\ce{}`, `\braket`, or `\color` render as a visible error placeholder rather than the intended output.

## 📖 Public Modules

- `MarkdownCore` - Markdown IR and parser output (`MarkdownDocument`, `BlockNode`, `InlineNode`)
- `MarkdownRenderKit` - `RenderPreparer`, `RenderSnapshot`, `RenderStyle`, fenced code syntax highlighting, source editor highlighting
- `MarkdownPlatformView` - `MarkdownLabelView`, `MarkdownEditorTextView`, editor commands and platform hosts
- `MarkdownKit` - SwiftUI `MarkdownText`, `MarkdownEditor`, plus the lower layers via re-export
- `MarkdownMath` - optional MathJax (JavaScriptCore) + SwiftDraw implementation of the `MathRendering` protocol for LaTeX math

## 📖 Supported Markdown Features

- ✅ Headings (H1-H6)
- ✅ **Bold**, *Italic*, ~~Strikethrough~~
- ✅ `Inline code` and fenced code blocks
- ✅ [Links](https://example.com)
- ✅ Images with async loading ![alt text](url)
- ✅ Ordered, unordered, and task lists
- ✅ Nested lists
- ✅ Block quotes
- ✅ Horizontal rules
- ✅ GFM tables including alignment markers
- ✅ LaTeX math (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) via the optional **MarkdownMath** product
- ✅ Incremental streaming updates
- ✅ Markdown source editor with token highlighting
- ✅ List continuation, empty-list exit, task toggle, and indent / outdent commands
- ✅ Common editor shortcuts for bold, italic, code, and links

## ✏️ Editor Scope

`MarkdownEditor` is optimized for long-form source editing with native scrolling, selection, IME handling, and undo / redo inherited from system text controls.

Included in the current editor release:
- Markdown token highlighting for headings, emphasis, links, block quotes, list markers, task markers, fenced code blocks, and inline code
- Fenced code block language highlighting through the shared `SyntaxHighlighter`
- Native source editing on iOS and macOS through `UITextView` / `NSTextView`

Not included in the current editor release:
- WYSIWYG rich-text editing
- Dedicated table editing UI
- Image paste to Markdown conversion
- Collaborative editing semantics

## 🖼️ Image Loading

MarkdownKit loads remote images asynchronously and reuses them across relayouts and style changes.

```swift
let markdown = """
# Example with Images

![MarkdownKit sample image](https://placehold.co/800x400.png?text=MarkdownKit)
"""

MarkdownText(markdown)
```

Images are automatically:
- Loaded asynchronously in the background
- Cached in memory for the lifetime of the view
- Displayed with placeholders during loading
- Scaled to fit available width while maintaining aspect ratio

## 🎨 Customization

Customize every aspect of your Markdown rendering through `RenderStyle`:

```swift
var style = RenderStyle.default

#if canImport(UIKit)
style.h1Font = .systemFont(ofSize: 34, weight: .bold)
style.h2Font = .systemFont(ofSize: 28, weight: .bold)
style.codeFont = .monospacedSystemFont(ofSize: 15, weight: .regular)
style.quoteBarColor = .systemBlue
#endif

style.paragraphSpacing = 14
style.quoteIndent = 24
```

## 🏗️ Architecture

MarkdownKit consists of four layers:

1. `MarkdownCore`: Parses Markdown into an intermediate representation using swift-markdown.
2. `MarkdownRenderKit`: Turns that intermediate representation into attributed text and provides shared syntax highlighting.
3. `MarkdownPlatformView`: Hosts the read-only view and the native source editor platform views.
4. `MarkdownKit`: Exposes SwiftUI `MarkdownText` and `MarkdownEditor`, then re-exports the lower layers.

## 🔍 Example

To run the example project:

```bash
git clone https://github.com/wxlpp/MarkdownKit.git
cd MarkdownKit
open Example/Example.xcodeproj
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

MarkdownKit is available under the MIT license. See [the LICENSE file](LICENSE) for more information.

## 👨‍💻 Author

Evan Wang

## 🙏 Acknowledgments

- [swift-markdown](https://github.com/swiftlang/swift-markdown) - The excellent Markdown parser
- Apple's TextKit 2 framework
