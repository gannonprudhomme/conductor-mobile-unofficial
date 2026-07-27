import XCTest

final class ConductorVisualUITests: XCTestCase {
    func testCloudSessionActivity() throws {
        let app = XCUIApplication(
            bundleIdentifier: "com.gannonprudhomme.conductor-mobile-unofficial"
        )
        app.launch()

        let workspace = app.staticTexts["Manage model settings"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 15))
        workspace.tap()

        sleep(12)

        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(
            to: URL(fileURLWithPath: "/tmp/conductor-session-activity.png")
        )
    }
}
