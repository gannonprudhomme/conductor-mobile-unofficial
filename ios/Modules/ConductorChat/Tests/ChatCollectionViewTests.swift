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
    @Test("Content shorter than the viewport aligns to the top")
    func shortContentAlignment() {
        #expect(ChatCollectionView.contentAlignmentPoint == CGPoint(x: 0, y: 0))
    }

    @Test("Initial content opens at the bottom and later updates follow only while pinned")
    func scrollPolicy() {
        var policy = ChatCollectionView.ScrollPolicy()

        expectNoDifference(
            policy.rowsWillChange(hasRows: false),
            .none
        )
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .bottom(isInitial: true)
        )
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .bottom(isInitial: false)
        )

        policy.isFollowingBottom = false
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .preserveViewport
        )

        policy.scrollToBottomRequested()
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .bottom(isInitial: false)
        )

        expectNoDifference(
            policy.rowsWillChange(hasRows: false),
            .none
        )
        #expect(!policy.hasDisplayedContent)
        #expect(policy.isFollowingBottom)
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .bottom(isInitial: true)
        )
    }

    @Test("Summary disclosure preserves the viewport even while bottom-pinned")
    func summaryDisclosureScrollPolicy() {
        var policy = ChatCollectionView.ScrollPolicy()

        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .bottom(isInitial: true)
        )
        expectNoDifference(
            policy.rowsWillChange(
                hasRows: true,
                shouldPreserveViewport: true
            ),
            .preserveViewport
        )
        #expect(!policy.isFollowingBottom)
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .preserveViewport
        )

        policy.scrollToBottomRequested()
        expectNoDifference(
            policy.rowsWillChange(hasRows: true),
            .bottom(isInitial: false)
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

    @Test("Increasing the bottom inset keeps bottom-pinned content unobscured")
    func bottomInsetKeepsPinnedContentVisible() {
        let collectionView = TestCollectionView()
        let coordinator = ChatCollectionView.Coordinator()
        coordinator.connect(to: collectionView)
        defer { coordinator.disconnect() }

        coordinator.render(
            rows: [
                displayedRow(
                    .humanMessage(.init(id: "message", content: "Message"))
                ),
            ],
            animation: nil,
            turnSummaryTapped: { _ in },
            in: collectionView
        )
        collectionView.contentSize = CGSize(width: 390, height: 1_000)
        collectionView.contentOffset.y = 156

        coordinator.updateContentInset(
            UIEdgeInsets(top: 0, left: 0, bottom: 200, right: 0),
            animationDuration: nil,
            in: collectionView
        )

        #expect(collectionView.contentOffset.y == 356)
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

    @Test("Canonical confirmation preserves and reconfigures diffable identity")
    func confirmationPreservesDiffableIdentity() {
        let bubbleID = UUID()
        let optimisticMessage = displayedRow(
            .optimisticMessage(
                .init(
                    id: bubbleID,
                    content: "Test",
                    deliveryDetail: nil,
                    status: .unconfirmed
                )
            )
        )
        let canonicalMessage = displayedRow(
            .humanMessage(
                .init(id: bubbleID.uuidString, content: "Test")
            )
        )

        #expect(optimisticMessage.id == canonicalMessage.id)
        #expect(
            ChatCollectionView.changedRowIDs(
                previousRowsByID: [optimisticMessage.id: optimisticMessage],
                rows: [canonicalMessage]
            ) == [canonicalMessage.id]
        )
    }

    @Test("Only message growth and working-row insertion animate bottom follow")
    func bottomFollowAnimationPolicy() {
        let message = displayedRow(
            .humanMessage(.init(id: "message", content: "Before"))
        )
        let changedMessage = displayedRow(
            .humanMessage(.init(id: "message", content: "After"))
        )
        let appendedMessage = displayedRow(
            .humanMessage(.init(id: "appended", content: "Next"))
        )
        let progress = displayedRow(
            .turnInProgress(.init(id: "turn", startedAt: .distantPast))
        )
        let collapsedSummary = displayedRow(
            .turnSummary(
                .init(
                    id: "summary",
                    isExpanded: false,
                    toolCallCount: 1,
                    messageCount: 1,
                    toolIcons: []
                )
            )
        )
        let expandedSummary = displayedRow(
            .turnSummary(
                .init(
                    id: "summary",
                    isExpanded: true,
                    toolCallCount: 1,
                    messageCount: 1,
                    toolIcons: []
                )
            )
        )

        #expect(
            ChatCollectionView.shouldAnimateBottomFollow(
                from: [message],
                to: [changedMessage]
            )
        )
        #expect(
            ChatCollectionView.shouldAnimateBottomFollow(
                from: [message],
                to: [message, appendedMessage]
            )
        )
        #expect(
            ChatCollectionView.shouldAnimateBottomFollow(
                from: [message],
                to: [message, progress]
            )
        )
        #expect(
            !ChatCollectionView.shouldAnimateBottomFollow(
                from: [message, collapsedSummary],
                to: [message, expandedSummary, appendedMessage]
            )
        )
        #expect(
            !ChatCollectionView.shouldAnimateBottomFollow(
                from: [message, progress],
                to: [message]
            )
        )
        #expect(
            !ChatCollectionView.shouldAnimateBottomFollow(
                from: [message],
                to: [message]
            )
        )
        #expect(
            !ChatCollectionView.shouldAnimateBottomFollow(
                from: [],
                to: [message],
                isInitialContent: true
            )
        )
        #expect(
            !ChatCollectionView.shouldAnimateBottomFollow(
                from: [message],
                to: [changedMessage],
                isInteractionActive: true
            )
        )
        #expect(
            !ChatCollectionView.shouldAnimateBottomFollow(
                from: [message],
                to: [changedMessage],
                isReduceMotionEnabled: true
            )
        )
    }

    @Test("Expanded summary targets do not overlap neighboring rows")
    func expandedSummaryHitTarget() {
        let summaryFrame = CGRect(x: 0, y: 100, width: 390, height: 40)
        let neighboringFrame = CGRect(x: 0, y: 144, width: 390, height: 40)
        let visibleRowFrames = [summaryFrame, neighboringFrame]

        #expect(
            ChatCollectionView.isExpandedSummaryHit(
                CGPoint(x: 100, y: 142),
                summaryFrame: summaryFrame,
                visibleRowFrames: visibleRowFrames
            )
        )
        #expect(
            !ChatCollectionView.isExpandedSummaryHit(
                CGPoint(x: 100, y: 145),
                summaryFrame: summaryFrame,
                visibleRowFrames: visibleRowFrames
            )
        )
        #expect(
            !ChatCollectionView.isExpandedSummaryHit(
                CGPoint(x: 100, y: 120),
                summaryFrame: summaryFrame,
                visibleRowFrames: visibleRowFrames
            )
        )
    }

    @Test("Only the newest snapshot application can complete")
    func snapshotApplicationState() {
        var state = ChatCollectionView.SnapshotApplicationState()

        let firstA = state.begin()
        let b = state.begin()
        let secondA = state.begin()

        let didCompleteFirstA = state.complete(firstA)
        let didCompleteB = state.complete(b)
        #expect(!didCompleteFirstA)
        #expect(!didCompleteB)
        #expect(state.isPending)
        let didCompleteSecondA = state.complete(secondA)
        #expect(didCompleteSecondA)
        #expect(!state.isPending)

        let beforeInvalidation = state.begin()
        state.invalidate()
        let didCompleteBeforeInvalidation = state.complete(beforeInvalidation)
        #expect(!didCompleteBeforeInvalidation)
        #expect(!state.isPending)
    }

    @Test("Scroll correction waits for interaction to finish")
    func deferredScrollCorrection() {
        let collectionView = TestCollectionView()
        let coordinator = ChatCollectionView.Coordinator()
        coordinator.connect(to: collectionView)
        defer { coordinator.disconnect() }

        collectionView.isTrackingForTests = true
        coordinator.collectionViewDidLayout(collectionView)
        #expect(coordinator.needsScrollCorrection)

        let panGestureRecognizer = TestPanGestureRecognizer()
        panGestureRecognizer.stateForTests = .ended
        coordinator.scrollPanGestureDidChange(panGestureRecognizer)
        #expect(coordinator.needsScrollCorrection)

        collectionView.isTrackingForTests = false
        coordinator.scrollPanGestureDidChange(panGestureRecognizer)
        #expect(!coordinator.needsScrollCorrection)

        collectionView.isDraggingForTests = true
        coordinator.collectionViewDidLayout(collectionView)
        #expect(coordinator.needsScrollCorrection)

        collectionView.isDraggingForTests = false
        collectionView.isDeceleratingForTests = true
        coordinator.scrollViewDidEndDragging(
            collectionView,
            willDecelerate: true
        )
        #expect(coordinator.needsScrollCorrection)

        collectionView.isDeceleratingForTests = false
        coordinator.scrollViewDidEndDecelerating(collectionView)
        #expect(!coordinator.needsScrollCorrection)
    }

    @Test("Sending resumes bottom follow even before rows change")
    func sendResumesBottomFollow() {
        let collectionView = TestCollectionView()
        let coordinator = ChatCollectionView.Coordinator()
        coordinator.connect(to: collectionView)
        defer { coordinator.disconnect() }

        collectionView.isDraggingForTests = true
        coordinator.render(
            rows: [],
            scrollToBottomRequest: 1,
            animation: nil,
            turnSummaryTapped: { _ in },
            in: collectionView
        )
        #expect(coordinator.needsScrollToBottom)

        collectionView.isDraggingForTests = false
        coordinator.scrollViewDidEndDragging(
            collectionView,
            willDecelerate: false
        )
        #expect(coordinator.needsScrollToBottom)
        #expect(!coordinator.needsScrollCorrection)

        coordinator.scrollViewWillBeginDragging(collectionView)
        #expect(!coordinator.needsScrollToBottom)
    }

    @Test("Immediate row changes, dragging, and empty content stop native animation")
    func nativeScrollAnimationCancellation() {
        let collectionView = TestCollectionView()
        let coordinator = ChatCollectionView.Coordinator()
        coordinator.connect(to: collectionView)
        defer { coordinator.disconnect() }

        let message = displayedRow(
            .humanMessage(.init(id: "message", content: "Message"))
        )
        let collapsedSummary = displayedRow(
            .turnSummary(
                .init(
                    id: "summary",
                    isExpanded: false,
                    toolCallCount: 1,
                    messageCount: 1,
                    toolIcons: []
                )
            )
        )
        let expandedSummary = displayedRow(
            .turnSummary(
                .init(
                    id: "summary",
                    isExpanded: true,
                    toolCallCount: 1,
                    messageCount: 1,
                    toolIcons: []
                )
            )
        )
        coordinator.render(
            rows: [message, collapsedSummary],
            animation: nil,
            turnSummaryTapped: { _ in },
            in: collectionView
        )

        collectionView.isScrollAnimatingForTests = true
        coordinator.render(
            rows: [message, expandedSummary],
            animation: .default,
            turnSummaryTapped: { _ in },
            in: collectionView
        )
        #expect(collectionView.stopScrollingCount == 1)

        collectionView.isScrollAnimatingForTests = true
        coordinator.scrollViewWillBeginDragging(collectionView)
        #expect(collectionView.stopScrollingCount == 2)

        collectionView.isScrollAnimatingForTests = true
        coordinator.render(
            rows: [],
            animation: nil,
            turnSummaryTapped: { _ in },
            in: collectionView
        )
        #expect(collectionView.stopScrollingCount == 3)
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

private func displayedRow(
    _ content: DisplayedChatRow
) -> DisplayedChatRowWithPadding {
    DisplayedChatRowWithPadding(
        content: content,
        topPadding: 0,
        bottomPadding: 0
    )
}

private final class TestCollectionView: UICollectionView {
    var isTrackingForTests = false
    var isDraggingForTests = false
    var isDeceleratingForTests = false
    var isScrollAnimatingForTests = false
    var stopScrollingCount = 0

    override var isTracking: Bool { isTrackingForTests }
    override var isDragging: Bool { isDraggingForTests }
    override var isDecelerating: Bool { isDeceleratingForTests }
    override var isScrollAnimating: Bool { isScrollAnimatingForTests }

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func stopScrollingAndZooming() {
        stopScrollingCount += 1
        isScrollAnimatingForTests = false
    }

}

private final class TestPanGestureRecognizer: UIPanGestureRecognizer {
    var stateForTests: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
        get { stateForTests }
        set { stateForTests = newValue }
    }
}
