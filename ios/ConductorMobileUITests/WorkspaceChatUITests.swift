//
//  WorkspaceChatUITests.swift
//  ConductorMobileUITests
//
//  Created by Gannon Prudomme on 7/19/26.
//

import XCTest

@MainActor
final class WorkspaceChatUITests: XCTestCase {
    func testLongPressingSessionChipPresentsContextMenu() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-workspace-chat-ui-test"]
        app.launch()

        let workspace = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspaces.workspace."))
            .firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()

        let session = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-chat.session."))
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.press(forDuration: 1)

        let renameChatButton = app.buttons["Rename chat"]
        XCTAssertTrue(renameChatButton.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Copy concise transcript"].exists)
        XCTAssertTrue(app.buttons["Close tab"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Session chip context menu"
        attachment.lifetime = .keepAlways
        add(attachment)

        renameChatButton.tap()
        let chatNameField = app.textFields["Chat name"]
        XCTAssertTrue(chatNameField.waitForExistence(timeout: 2))

        let renameButton = app.buttons["Rename"]
        XCTAssertTrue(renameButton.exists)
        XCTAssertFalse(renameButton.isEnabled)

        chatNameField.tap()
        chatNameField.typeText(" edited")
        XCTAssertTrue(renameButton.isEnabled)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }
}
