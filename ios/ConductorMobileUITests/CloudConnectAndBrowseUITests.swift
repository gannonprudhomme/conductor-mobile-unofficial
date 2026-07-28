//
//  CloudConnectAndBrowseUITests.swift
//  ConductorMobileUITests
//
//  Created by Gannon Prudomme on 7/27/26.
//

import XCTest

final class CloudConnectAndBrowseUITests: XCTestCase {
    @MainActor
    func testCloudWorkspacesOpenReadOnlySessionsAndTranscripts() {
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

        let cloudOnlyRow = element("workspaces.workspace.cloud-only", in: app)
        XCTAssertTrue(cloudOnlyRow.waitForExistence(timeout: 10))
        cloudOnlyRow.tap()
        XCTAssertTrue(
            app.staticTexts["Cloud only fixture"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("workspace-chat.session.cloud-session-working", in: app)
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("workspace-chat.session.cloud-session-idle", in: app)
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts["Inspect the Cloud workspace."]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["I will inspect it now."].exists)
        XCTAssertTrue(app.staticTexts["git status --short"].exists)
        XCTAssertTrue(app.staticTexts["Working tree clean"].exists)
        XCTAssertTrue(app.staticTexts["Synthetic Cloud fixture error"].exists)
        XCTAssertTrue(
            element("chat.cloud-read-only", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(element("workspace-chat.new-session", in: app).exists)
        XCTAssertFalse(element("chat.send", in: app).exists)
        XCTAssertFalse(app.buttons["Workspace actions"].exists)

        element("workspace-chat.session.cloud-session-idle", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["Cached Cloud transcript"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["This session came from the Cloud API."].exists)
        XCTAssertTrue(element("chat.cloud-read-only", in: app).exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(cloudOnlyRow.waitForExistence(timeout: 5))
        cloudOnlyRow.tap()
        XCTAssertTrue(
            app.staticTexts["Inspect the Cloud workspace."]
                .waitForExistence(timeout: 10)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let enrichedRow = element("workspaces.workspace.local-draft", in: app)
        XCTAssertTrue(enrichedRow.waitForExistence(timeout: 5))
        enrichedRow.tap()
        XCTAssertTrue(
            element("workspace-chat.session.enriched-cloud-session", in: app)
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts["Cached Cloud transcript"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(element("chat.cloud-read-only", in: app).exists)
        XCTAssertFalse(element("workspace-chat.new-session", in: app).exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let workingRow = element("workspaces.workspace.local-working", in: app)
        XCTAssertTrue(workingRow.waitForExistence(timeout: 5))
        workingRow.tap()
        XCTAssertTrue(
            app.staticTexts["Local working fixture"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Local controls remain available."]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(element("workspace-chat.new-session", in: app).exists)
        XCTAssertTrue(element("chat.send", in: app).exists)
        XCTAssertTrue(app.buttons["Workspace actions"].exists)
        XCTAssertFalse(element("chat.cloud-read-only", in: app).exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    func testCloudAndLocalSettingsAreInteractive() {
        let app = launch(fixture: "cloud-connect-and-browse")

        app.buttons["Settings"].tap()
        let cloudHeader = app.staticTexts["Conductor Cloud"]
        let localHeader = app.staticTexts["Local Mac"]
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
            element("workspaces.workspace.cloud-only", in: loadingApp)
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

        let draftRow = element("workspaces.workspace.local-draft", in: app)
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
