//
//  CloudConnectAndBrowseUITests.swift
//  ConductorMobileUITests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import XCTest

final class CloudConnectAndBrowseUITests: XCTestCase {
    @MainActor
    func testUnifiedRowsAndSettingsAreInteractive() {
        let app = launch(fixture: "cloud-connect-and-browse")

        XCTAssertTrue(app.staticTexts["Conductor"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            element("cloud-status.connected", in: app)
                .waitForExistence(timeout: 10)
        )
        let cloudStatus = element("cloud-status.connected", in: app)
        let localStatus = element("MacBook Pro", in: app)
        XCTAssertTrue(localStatus.exists)
        XCTAssertLessThan(cloudStatus.frame.minX, localStatus.frame.minX)
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
        let cloudHeader = app.staticTexts["Conductor Cloud"]
        let localHeader = app.staticTexts["Connection"]
        XCTAssertTrue(cloudHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(localHeader.exists)
        XCTAssertLessThan(cloudHeader.frame.minY, localHeader.frame.minY)
        XCTAssertFalse(app.staticTexts["Conductor Cloud · Experimental"].exists)
        XCTAssertFalse(app.buttons["Replace cloud API key"].exists)

        let apiKeyField = app.secureTextFields["cloudAPIKeyField"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 5))
        let testCloudButton = app.buttons["Test cloud connection"]
        XCTAssertTrue(testCloudButton.exists)
        XCTAssertGreaterThan(testCloudButton.frame.minX, apiKeyField.frame.minX)
        XCTAssertTrue(app.buttons["Delete"].exists)

        apiKeyField.tap()
        apiKeyField.typeText("intentionally-invalid-api-key")
        app.buttons["Save settings"].tap()

        XCTAssertTrue(
            app.alerts["Failed to connect to Conductor Cloud"]
                .waitForExistence(timeout: 30)
        )
    }

    @MainActor
    func testCloudOnlyLoadingAndAuthenticationFailureArePassive() {
        let loadingApp = launch(fixture: "cloud-only-loading")

        XCTAssertTrue(
            element("cloud-status.loading", in: loadingApp)
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(element("Cloud", in: loadingApp).exists)
        XCTAssertTrue(
            element("workspace-row.cloud-only", in: loadingApp)
                .waitForExistence(timeout: 10)
        )
        XCTAssertFalse(element("MacBook Pro", in: loadingApp).exists)
        loadingApp.terminate()

        let failingApp = launch(fixture: "cloud-authentication-failure")
        XCTAssertTrue(
            failingApp.alerts["Cloud authentication failed"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(element("cloud-status.failed", in: failingApp).exists)
        failingApp.alerts.buttons["Open Settings"].tap()
        XCTAssertTrue(
            failingApp.secureTextFields["cloudAPIKeyField"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testLocalOnlyDoesNotShowCloudStatus() {
        let app = launch(fixture: "local-only")

        XCTAssertTrue(element("MacBook Pro", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("cloud-status.connected", in: app).exists)
        XCTAssertFalse(element("cloud-status.loading", in: app).exists)
        XCTAssertFalse(element("cloud-status.failed", in: app).exists)
        XCTAssertFalse(element("Cloud", in: app).exists)

        let draftRow = element("workspace-row.local-draft", in: app)
        XCTAssertTrue(draftRow.waitForExistence(timeout: 10))
        draftRow.tap()
        XCTAssertTrue(
            app.staticTexts["Local draft fixture"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUCTOR_UI_TEST_FIXTURE"] = fixture
        app.launch()
        return app
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
