//
//  ChatCollectionViewTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/14/26.
//

@testable import ConductorChat
import CustomDump
import Testing
import UIKit

@MainActor
struct ChatCollectionViewTests {
    @Test("Initial content opens at the bottom and later updates follow only while pinned")
    func scrollPolicy() {
        var policy = ChatCollectionView.ScrollPolicy()

        expectNoDifference(
            policy.rowsWillChange(sessionID: "one", hasRows: false),
            .none
        )
        expectNoDifference(
            policy.rowsWillChange(sessionID: "one", hasRows: true),
            .bottom(isInitial: true)
        )
        expectNoDifference(
            policy.rowsWillChange(sessionID: "one", hasRows: true),
            .bottom(isInitial: false)
        )

        policy.isFollowingBottom = false
        expectNoDifference(
            policy.rowsWillChange(sessionID: "one", hasRows: true),
            .preserveViewport
        )

        expectNoDifference(
            policy.rowsWillChange(sessionID: "one", hasRows: false),
            .none
        )
        #expect(!policy.hasDisplayedContent)
        #expect(policy.isFollowingBottom)
        expectNoDifference(
            policy.rowsWillChange(sessionID: "one", hasRows: true),
            .bottom(isInitial: true)
        )
        expectNoDifference(
            policy.rowsWillChange(sessionID: "two", hasRows: true),
            .bottom(isInitial: true)
        )
    }

    @Test("Bottom geometry includes adjusted insets and handles short content")
    func bottomGeometry() {
        let insets = UIEdgeInsets(top: 20, left: 0, bottom: 30, right: 0)

        #expect(
            ChatCollectionView.bottomOffsetY(
                contentHeight: 1_000,
                boundsHeight: 500,
                adjustedContentInset: insets
            ) == 530
        )
        #expect(
            ChatCollectionView.bottomOffsetY(
                contentHeight: 100,
                boundsHeight: 500,
                adjustedContentInset: insets
            ) == -20
        )
        #expect(
            ChatCollectionView.isBottomPinned(
                contentHeight: 1_000,
                boundsHeight: 500,
                contentOffsetY: 528.5,
                adjustedContentInset: insets
            )
        )
        #expect(
            !ChatCollectionView.isBottomPinned(
                contentHeight: 1_000,
                boundsHeight: 500,
                contentOffsetY: 527,
                adjustedContentInset: insets
            )
        )
        #expect(
            ChatCollectionView.isBottomPinned(
                contentHeight: 100,
                boundsHeight: 500,
                contentOffsetY: -80,
                adjustedContentInset: insets
            )
        )
        #expect(
            !ChatCollectionView.isBottomPinned(
                contentHeight: 1_000,
                boundsHeight: 500,
                contentOffsetY: -80,
                adjustedContentInset: insets
            )
        )
    }

    @Test("Layout observation includes adjusted content inset changes")
    func layoutObservation() {
        let collectionView = ChatCollectionView.LayoutObservingCollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        var changeCount = 0
        collectionView.layoutDidChange = { _ in
            changeCount += 1
        }

        collectionView.layoutSubviews()
        changeCount = 0
        collectionView.contentInset.bottom = 20
        collectionView.layoutSubviews()

        #expect(changeCount == 1)
    }

    @Test("Stable row IDs are reconfigured when their rendered content changes")
    func changedRowIDs() {
        let previous = DisplayedChatRowWithPadding(
            content: .humanMessage(.init(id: "message", content: "Before")),
            topPadding: 24,
            bottomPadding: 12
        )
        let changed = DisplayedChatRowWithPadding(
            content: .humanMessage(.init(id: "message", content: "After")),
            topPadding: 24,
            bottomPadding: 12
        )
        let previousPadding = DisplayedChatRowWithPadding(
            content: .assistantError(messageID: "padding", message: "Same"),
            topPadding: 0,
            bottomPadding: 0
        )
        let changedPadding = DisplayedChatRowWithPadding(
            content: previousPadding.content,
            topPadding: 0,
            bottomPadding: 12
        )
        let unchanged = DisplayedChatRowWithPadding(
            content: .humanMessage(.init(id: "other", content: "Same")),
            topPadding: 24,
            bottomPadding: 12
        )

        expectNoDifference(
            ChatCollectionView.changedRowIDs(
                previousRowsByID: [
                    previous.id: previous,
                    previousPadding.id: previousPadding,
                    unchanged.id: unchanged,
                ],
                rows: [changed, changedPadding, unchanged]
            ),
            [changed.id, changedPadding.id]
        )
    }

    @Test("Bottom animation is interrupted only when scrolling moves away from its target")
    func bottomAnimationInterruption() {
        #expect(
            !ChatCollectionView.shouldInterruptBottomAnimation(
                previousDistanceToTarget: 100,
                currentDistanceToTarget: 80
            )
        )
        #expect(
            !ChatCollectionView.shouldInterruptBottomAnimation(
                previousDistanceToTarget: 100,
                currentDistanceToTarget: 102
            )
        )
        #expect(
            ChatCollectionView.shouldInterruptBottomAnimation(
                previousDistanceToTarget: 100,
                currentDistanceToTarget: 102.1
            )
        )
    }

    @Test("Viewport restoration uses the first surviving anchor and clamps its offset")
    func restoredOffset() {
        let anchors = [
            ChatCollectionView.ViewportAnchorItem(id: "removed", offset: -10),
            ChatCollectionView.ViewportAnchorItem(id: "surviving", offset: 20),
        ]

        #expect(
            ChatCollectionView.restoredOffsetY(
                anchorItems: anchors,
                minimumOffsetY: -30,
                maximumOffsetY: 500
            ) { id in
                id == "surviving" ? 120 : nil
            } == 100
        )
        #expect(
            ChatCollectionView.restoredOffsetY(
                anchorItems: anchors,
                minimumOffsetY: -30,
                maximumOffsetY: 80
            ) { id in
                id == "surviving" ? 120 : nil
            } == 80
        )
        #expect(
            ChatCollectionView.restoredOffsetY(
                anchorItems: anchors,
                minimumOffsetY: -30,
                maximumOffsetY: 500
            ) { id in
                id == "surviving" ? -20 : nil
            } == -30
        )
        #expect(
            ChatCollectionView.restoredOffsetY(
                anchorItems: anchors,
                minimumOffsetY: -30,
                maximumOffsetY: 500
            ) { _ in nil } == nil
        )
    }
}
