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
}
