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
}
