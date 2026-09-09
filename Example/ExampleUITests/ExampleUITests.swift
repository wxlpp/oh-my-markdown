import XCTest

final class ExampleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRootDemoIsAccessible() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.otherElements["markdownkit.example.root"].waitForExistence(timeout: 10))
    }

    /// The rendered document must reach the accessibility tree as **many**
    /// elements in reading order, not as one.
    ///
    /// It read as one for the whole of this branch until a reader reported it:
    /// the view conforms to `UITextInput`, and UIKit answers `isAccessibilityElement`
    /// with `true` for such a view whatever the stored property says, so the 134
    /// elements the view had built were never asked for. Counting elements here
    /// is the only place that can catch that — the view's own array was correct
    /// throughout.
    @MainActor
    func testRenderedMarkdownIsTraversedElementByElement() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.otherElements["markdownkit.example.root"].waitForExistence(timeout: 15))

        let texts = app.staticTexts
        XCTAssertTrue(texts.element(boundBy: 0).waitForExistence(timeout: 10))
        // The sample document has well over a hundred leaves; the nav title alone
        // is one element, which is what a collapsed document used to look like.
        XCTAssertGreaterThan(texts.count, 20, "the document collapsed into a single element")

        // Reading order, from the top of the sample: title, its paragraph, the
        // next heading. Only the first few, because a query per element is slow.
        let labels = (0 ..< min(texts.count, 6)).map { texts.element(boundBy: $0).label }
        for label in labels {
            XCTAssertFalse(label.isEmpty, "an exposed element speaks nothing")
        }
        XCTAssertTrue(
            labels.contains { $0.hasPrefix("基于 TextKit 2") },
            "the opening paragraph is not its own element: \(labels)"
        )
        XCTAssertTrue(
            labels.contains("文字格式"),
            "the second heading is not its own element: \(labels)"
        )
    }

    /// The reader's text size has to reach the rendered document through the real
    /// app: the trait, the SwiftUI host, the label view and the render session.
    /// Measured as the height of the label view itself — it reports its whole
    /// content, not the visible window — because a TextKit-drawn document exposes
    /// no font that XCUITest can read.
    @MainActor
    func testTheRenderedDocumentGrowsWithTheTextSize() {
        func documentHeight(_ category: String) -> CGFloat {
            let app = XCUIApplication()
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", category]
            app.launch()
            XCTAssertTrue(app.otherElements["markdownkit.example.root"].waitForExistence(timeout: 10))
            let document = app.textViews.element(boundBy: 0)
            XCTAssertTrue(document.waitForExistence(timeout: 10))
            // The render tab holds the only text view today. Checking what it
            // says keeps the measurement honest if the editor's ever joins it.
            XCTAssertTrue(
                (document.value as? String ?? "").hasPrefix("MarkdownKit"),
                "measured something other than the rendered document"
            )
            return document.frame.height
        }
        let large = documentHeight("UICTContentSizeCategoryL")
        let accessibility = documentHeight("UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertGreaterThan(large, 0)
        XCTAssertGreaterThan(accessibility, large, "the document did not grow with the reader's text size")
    }
}
