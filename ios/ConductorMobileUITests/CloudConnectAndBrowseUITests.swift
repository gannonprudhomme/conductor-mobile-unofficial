//
//  CloudConnectAndBrowseUITests.swift
//  ConductorMobileUITests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import XCTest

final class CloudConnectAndBrowseUITests: XCTestCase {
    @MainActor
    func testCloudRowsAndSettingsAreInteractive() {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUCTOR_UI_TEST_FIXTURE"] =
            "cloud-connect-and-browse"
        app.launch()

        XCTAssertTrue(app.staticTexts["Conductor"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            element("Preparing", in: app).waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("Draft pull request", in: app).waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("Working", in: app).waitForExistence(timeout: 10)
        )

        let cloudOnlyRow = element("workspace-row.cloud-only", in: app)
        XCTAssertTrue(cloudOnlyRow.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons.matching(identifier: "workspace-row.cloud-only")
                .firstMatch.exists
        )
        XCTAssertTrue(app.staticTexts["Conductor"].exists)

        let draftRow = element("workspace-row.local-draft", in: app)
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10))
        draftRow.tap()
        XCTAssertTrue(
            app.staticTexts["Local draft fixture"].waitForExistence(timeout: 5)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let workingRow = element("workspace-row.local-working", in: app)
        XCTAssertTrue(workingRow.waitForExistence(timeout: 5))
        workingRow.tap()
        XCTAssertTrue(
            app.staticTexts["Local working fixture"].waitForExistence(timeout: 5)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Settings"].tap()
        let apiKeyField = app.secureTextFields["cloudAPIKeyField"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 5))
        apiKeyField.tap()
        apiKeyField.typeText("intentionally-invalid-api-key")
        app.buttons["Test cloud connection"].tap()

        XCTAssertTrue(
            app.alerts["Failed to connect to Conductor Cloud"]
                .waitForExistence(timeout: 30)
        )
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }
}
