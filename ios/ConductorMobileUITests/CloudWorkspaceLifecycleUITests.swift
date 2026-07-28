//
//  CloudWorkspaceLifecycleUITests.swift
//  ConductorMobileUITests
//
//  Created by Gannon Prudomme on 7/28/26.
//

import XCTest
import UIKit

@MainActor
final class CloudWorkspaceLifecycleUITests: XCTestCase {
    private let repositoryName = "conductor-mobile-unofficial"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLocalAndCloudWorkspaceLifecycle() throws {
        guard let apiKey = ProcessInfo.processInfo.environment["CONDUCTOR_E2E_API_KEY"],
              !apiKey.isEmpty else {
            throw XCTSkip("Set CONDUCTOR_E2E_API_KEY to run the real Cloud lifecycle test.")
        }

        let app = XCUIApplication()
        installLocalNetworkPermissionHandler()
        app.launch()

        if app.secureTextFields["cloudAPIKeyField"]
            .waitForExistence(timeout: 5) {
            configureConnections(in: app, apiKey: apiKey)
        }

        XCTAssertTrue(
            app.otherElements["cloud-status.connected"]
                .waitForExistence(timeout: 60),
            "Cloud never reached the connected state."
        )
        XCTAssertTrue(
            connectedLocalStatus(in: app).waitForExistence(timeout: 30),
            "The desktop relay never reached the connected state."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["workspaces.local-loaded"]
                .waitForExistence(timeout: 60),
            "The desktop relay connected without delivering its initial workspace snapshot."
        )

        selectRepositoryFilter(in: app)
        let baselineWorkspaceIDs = waitForWorkspaceIdentifiers(in: app)

        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        XCTAssertTrue(createButton.isEnabled)
        createButton.tap()

        let localButton = app.buttons["Local"]
        let cloudButton = app.buttons["Cloud"]
        XCTAssertTrue(
            localButton.waitForExistence(timeout: 15),
            "Local creation was not available for the shared repository."
        )
        XCTAssertTrue(
            cloudButton.waitForExistence(timeout: 15),
            "Cloud creation was not available for the shared repository."
        )
        XCTAssertEqual(
            app.buttons["Repository"].value as? String,
            repositoryName
        )

        cloudButton.tap()
        XCTAssertEqual(
            app.buttons["Repository"].value as? String,
            repositoryName
        )

        let submitButton = app.buttons["create-workspace.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        XCTAssertTrue(submitButton.isEnabled)
        submitButton.tap()

        let sessionPicker = app.descendants(matching: .any)[
            "workspace-chat.session-picker"
        ]
        XCTAssertTrue(
            sessionPicker.waitForExistence(timeout: 120),
            "Cloud workspace creation did not navigate to chat."
        )

        let initialSession = waitForSessionCount(1, in: app).first!
        let initialSessionID = initialSession.identifier
        let newSessionButton = app.buttons["workspace-chat.new-session"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 60))
        XCTAssertTrue(newSessionButton.isEnabled)
        newSessionButton.tap()

        let sessions = waitForSessionCount(2, in: app)
        XCTAssertEqual(sessions.count, 2)
        let createdSession = try XCTUnwrap(
            sessions.first { $0.identifier != initialSessionID }
        )

        assertSelection(
            initialSessionID,
            afterTapping: sessionButton(initialSessionID, in: app),
            in: app
        )
        assertSelection(
            createdSession.identifier,
            afterTapping: createdSession,
            in: app
        )
        assertSelection(
            initialSessionID,
            afterTapping: sessionButton(initialSessionID, in: app),
            in: app
        )

        navigateBackToWorkspaces(in: app)
        XCTAssertEqual(
            app.buttons["Filter workspaces"].value as? String,
            "Filtered by \(repositoryName)"
        )

        let createdWorkspaceID = waitForAddedWorkspaceIdentifier(
            baseline: baselineWorkspaceIDs,
            in: app
        )
        let createdWorkspace = workspaceElement(createdWorkspaceID, in: app)
        XCTAssertTrue(createdWorkspace.waitForExistence(timeout: 10))
        createdWorkspace.tap()

        let workspaceActions = app.buttons["Workspace actions"]
        XCTAssertTrue(workspaceActions.waitForExistence(timeout: 30))
        workspaceActions.tap()

        let archiveButton = app.buttons["Archive"]
        XCTAssertTrue(archiveButton.waitForExistence(timeout: 10))
        archiveButton.tap()

        XCTAssertTrue(
            app.buttons["Filter workspaces"].waitForExistence(timeout: 60),
            "Archiving did not return to the workspace list."
        )
        XCTAssertTrue(
            workspaceElement(createdWorkspaceID, in: app)
                .waitForNonExistence(timeout: 60),
            "The archived Cloud workspace remained in the filtered list."
        )
        XCTAssertEqual(
            Set(workspaceIdentifiers(in: app)),
            baselineWorkspaceIDs
        )
    }

    private func configureConnections(
        in app: XCUIApplication,
        apiKey: String
    ) {
        let apiKeyField = app.secureTextFields["cloudAPIKeyField"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 15))
        apiKeyField.tap()
        UIPasteboard.general.string = apiKey
        apiKeyField.press(forDuration: 1)
        let pasteButton = app.menuItems["Paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 10))
        pasteButton.tap()

        let serverAddressField = app.textFields["serverAddressField"]
        scrollToElement(serverAddressField, in: app)
        serverAddressField.tap()
        serverAddressField.typeText("127.0.0.1")

        let saveButton = app.buttons["Save settings"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()
        allowLocalNetworkAccessIfRequested()

        XCTAssertTrue(
            saveButton.waitForNonExistence(timeout: 60),
            "Settings did not dismiss after validating both connections."
        )
    }

    private func installLocalNetworkPermissionHandler() {
        addUIInterruptionMonitor(
            withDescription: "Local network access"
        ) { alert in
            for title in ["Allow", "Allow Paste"]
            where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    private func allowLocalNetworkAccessIfRequested() {
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else {
            return
        }
        for title in ["Allow", "OK"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return
        }
    }

    private func connectedLocalStatus(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)["local-status.connected"]
    }

    private func selectRepositoryFilter(in app: XCUIApplication) {
        let filterButton = app.buttons["Filter workspaces"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 30))
        filterButton.tap()

        let repositoryMenu = app.buttons
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Repository"
                )
            )
            .firstMatch
        XCTAssertTrue(repositoryMenu.waitForExistence(timeout: 10))
        repositoryMenu.tap()

        let repositoryList = app.collectionViews.firstMatch
        XCTAssertTrue(repositoryList.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(
            repositoryList.cells.count,
            1,
            "The repository menu did not contain a selectable repository."
        )
        repositoryList.cells.element(boundBy: 0).tap()

        let predicate = NSPredicate(
            format: "value == %@",
            "Filtered by \(repositoryName)"
        )
        expectation(for: predicate, evaluatedWith: filterButton)
        waitForExpectations(timeout: 10)
    }

    private func waitForWorkspaceIdentifiers(
        in app: XCUIApplication
    ) -> Set<String> {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@",
            "workspace-row."
        )
        let query = app.descendants(matching: .any).matching(predicate)
        _ = query.firstMatch.waitForExistence(timeout: 10)
        return Set(query.allElementsBoundByIndex.map(\.identifier))
    }

    private func workspaceIdentifiers(
        in app: XCUIApplication
    ) -> [String] {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "workspace-row."
                )
            )
            .allElementsBoundByIndex
            .map(\.identifier)
    }

    private func waitForAddedWorkspaceIdentifier(
        baseline: Set<String>,
        in app: XCUIApplication
    ) -> String {
        let predicate = NSPredicate { _, _ in
            Set(self.workspaceIdentifiers(in: app))
                .subtracting(baseline)
                .count == 1
        }
        expectation(for: predicate, evaluatedWith: app)
        waitForExpectations(timeout: 60)
        return Set(workspaceIdentifiers(in: app))
            .subtracting(baseline)
            .first!
    }

    private func sessionButton(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons
            .matching(
                NSPredicate(
                    format: "identifier == %@",
                    identifier
                )
            )
            .firstMatch
    }

    private func workspaceElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == %@",
                    identifier
                )
            )
            .firstMatch
    }

    private func waitForSessionCount(
        _ count: Int,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let query = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "workspace-chat.session."
            )
        )
        let predicate = NSPredicate { _, _ in
            query.count == count
                && query.allElementsBoundByIndex.allSatisfy(\.isEnabled)
        }
        expectation(for: predicate, evaluatedWith: app)
        waitForExpectations(timeout: 120)
        return query.allElementsBoundByIndex
    }

    private func assertSelection(
        _ identifier: String,
        afterTapping element: XCUIElement,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isEnabled)
        element.tap()

        let selected = sessionButton(identifier, in: app)
        let predicate = NSPredicate(format: "value == %@", "Selected")
        expectation(for: predicate, evaluatedWith: selected)
        waitForExpectations(timeout: 30)

        let selectedButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "workspace-chat.session.",
                "Selected"
            )
        )
        XCTAssertEqual(selectedButtons.count, 1)
    }

    private func navigateBackToWorkspaces(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()
        XCTAssertTrue(
            app.buttons["Filter workspaces"].waitForExistence(timeout: 30)
        )
    }

    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<5 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
