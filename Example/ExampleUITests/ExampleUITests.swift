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

    /// End-to-end check that rendered markdown reaches the accessibility tree
    /// with something to say.
    ///
    /// It deliberately does *not* assert one element per semantic leaf. Through
    /// SwiftUI hosting the XCUITest tree shows the whole document as a single
    /// element, while the view itself exposes four (see
    /// `MarkdownAccessibilityPlatformTests`); which of the two VoiceOver actually
    /// traverses could not be determined in this environment, and the Task 10
    /// record carries the measurement.
    func testRenderedMarkdownReachesTheAccessibilityTree() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.otherElements["markdownkit.example.root"].waitForExistence(timeout: 10))

        let texts = app.staticTexts
        XCTAssertTrue(texts.element(boundBy: 0).waitForExistence(timeout: 10))
        // First five only: XCUITest's element queries are slow enough that
        // walking a whole rendered document dominates the suite's runtime.
        for index in 0 ..< min(texts.count, 5) {
            XCTAssertFalse(texts.element(boundBy: index).label.isEmpty, "an exposed element speaks nothing")
        }
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
            return document.frame.height
        }
        let large = documentHeight("UICTContentSizeCategoryL")
        let accessibility = documentHeight("UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertGreaterThan(large, 0)
        XCTAssertGreaterThan(accessibility, large, "the document did not grow with the reader's text size")
    }
}
