//
//  ChatCollectionView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/14/26.
//  Definitely pretty sloppy, need to clean this up

import ConductorDesign
import SwiftUI
import UIKit

/// SwiftUI still owns the ordered row values and actions. The collection view owns cell reuse,
/// self-sizing layout, diffable updates, and transient scroll interaction.
@MainActor
struct ChatCollectionView: UIViewRepresentable {
    /// Top-aligns content that is shorter than the collection view's viewport.
    static let contentAlignmentPoint = CGPoint(x: 0, y: 0)

    /// The complete ordered presentation model for the collection view's single section.
    let rows: [DisplayedChatRowWithPadding]

    /// Changes when the scroll-down button requests animated bottom placement.
    let animatedScrollToBottomRequest: Int

    /// Changes whenever an accepted send should resume bottom-following.
    let scrollToBottomRequest: Int

    /// Retrieved from GeometryProxy
    let safeAreaInsets: EdgeInsets

    /// Duration shared with the SwiftUI bottom bar when an animated transaction changes its inset.
    let contentInsetAnimationDuration: TimeInterval

    /// Reports whether the feed is at least one visible viewport from its effective bottom.
    let scrollDownButtonVisibilityChanged: @MainActor (Bool) -> Void

    /// Sends summary disclosure taps back to the SwiftUI/TCA feature that owns expansion state.
    let turnSummaryTapped: @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void

    /// Creates the long-lived UIKit delegate and diffable-data-source owner.
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Creates and configures the collection view once for this representable's lifetime.
    func makeUIView(context: Context) -> LayoutObservingCollectionView {
        let collectionView = LayoutObservingCollectionView(
            frame: .zero,
            collectionViewLayout: Self.makeLayout()
        )
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.contentAlignmentPoint = Self.contentAlignmentPoint
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.accessibilityIdentifier = "chat.scroll"
        collectionView.delegate = context.coordinator

        // UICollectionView has no delegate callback for every geometry change that can move the
        // effective bottom. The subclass reports those changes to the same reconciliation path.
        let coordinator = context.coordinator
        collectionView.layoutDidChange = { [weak coordinator] collectionView in
            coordinator?.collectionViewDidLayout(collectionView)
        }
        coordinator.connect(to: collectionView)
        return collectionView
    }

    /// Renders the latest immutable SwiftUI input into the existing UIKit object graph.
    /// This may be called repeatedly with the same values, so both inset and row updates are
    /// idempotent.
    func updateUIView(
        _ collectionView: LayoutObservingCollectionView,
        context: Context
    ) {
        let contentInset = UIEdgeInsets(
            top: safeAreaInsets.top,
            left: safeAreaInsets.leading,
            bottom: safeAreaInsets.bottom,
            right: safeAreaInsets.trailing
        )
        context.coordinator.updateContentInset(
            contentInset,
            animationDuration: context.transaction.animation == nil
                ? nil
                : contentInsetAnimationDuration,
            in: collectionView
        )
        context.coordinator.render(
            rows: rows,
            animatedScrollToBottomRequest: animatedScrollToBottomRequest,
            scrollToBottomRequest: scrollToBottomRequest,
            animation: context.transaction.animation,
            scrollDownButtonVisibilityChanged: scrollDownButtonVisibilityChanged,
            turnSummaryTapped: turnSummaryTapped,
            in: collectionView
        )
    }

    /// Detaches callbacks and invalidates transient state before UIKit releases the view.
    static func dismantleUIView(
        _ collectionView: LayoutObservingCollectionView,
        coordinator: Coordinator
    ) {
        collectionView.layoutDidChange = nil
        collectionView.delegate = nil
        coordinator.disconnect()
    }

    /// Builds a one-column, full-width, self-sizing layout for heterogeneous SwiftUI rows.
    private static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(44)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: itemSize,
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = ChatRowLayout.stackSpacing
        section.contentInsets.bottom = ChatRowLayout.stackSpacing + 1
        return UICollectionViewCompositionalLayout(section: section)
    }
}

extension ChatCollectionView {
    /// A stable visible row and its vertical position relative to `contentOffset.y`.
    /// The coordinator captures several candidates so restoration can survive row deletion.
    struct ViewportAnchorItem: Equatable {
        /// Diffable identity used to find the same row after a snapshot is applied.
        let id: DisplayedChatRow.ID

        /// The row's `frame.minY - contentOffset.y` before the update.
        let offset: CGFloat
    }

    /// The scroll-position work required after a row snapshot is applied.
    enum UpdateIntent: Equatable {
        /// There is no content to position.
        case none

        /// Keep the feed at the bottom; initial content additionally needs one-time placement.
        case bottom(isInitial: Bool)

        /// Keep the user's current visible rows in place instead of following new content.
        case preserveViewport
    }

    /// Converts row changes into high-level scroll intent.
    ///
    /// This state is needed because geometry alone cannot distinguish initial placement from a
    /// later update, and the user's last bottom-pinned state must survive snapshot application.
    struct ScrollPolicy {
        /// Whether this collection view has already accepted at least one nonempty row set.
        private(set) var hasDisplayedContent = false

        /// Whether new content should continue following the bottom.
        var isFollowingBottom = true

        /// Makes the current bottom authoritative again after the user sends a message.
        mutating func scrollToBottomRequested() {
            isFollowingBottom = true
        }

        /// Records an incoming row set and returns the placement policy to use after its snapshot.
        mutating func rowsWillChange(
            hasRows: Bool,
            shouldPreserveViewport: Bool = false
        ) -> UpdateIntent {
            // Empty content has no anchor. Resetting here makes the next nonempty update initial
            // content again rather than an append to content that is no longer displayed.
            guard hasRows else {
                hasDisplayedContent = false
                isFollowingBottom = true
                return .none
            }

            // Initial content always opens at the bottom. Later content follows only while the
            // user remains pinned; otherwise the coordinator restores the visible viewport.
            // Disclosure changes also preserve the viewport so expanding a summary does not move
            // its header just because the feed was previously bottom-pinned.
            let isInitial = !hasDisplayedContent
            hasDisplayedContent = true
            if !isInitial, shouldPreserveViewport {
                isFollowingBottom = false
                return .preserveViewport
            }
            return isInitial || isFollowingBottom
                ? .bottom(isInitial: isInitial)
                : .preserveViewport
        }
    }

    /// Rejects completions from superseded asynchronous diffable snapshot applications.
    ///
    /// Each apply gets a unique token so only the newest pending completion may reconcile
    /// scrolling.
    struct SnapshotApplicationState {
        /// The latest token issued or invalidated by the coordinator.
        private(set) var generation = 0

        /// The token whose `dataSource.apply` completion is currently allowed to act.
        private(set) var pendingGeneration: Int?

        /// Whether layout callbacks must defer correction to a snapshot completion.
        var isPending: Bool {
            pendingGeneration != nil
        }

        /// Starts a new application and supersedes any older pending completion.
        mutating func begin() -> Int {
            // `&+=` wraps instead of trapping at Int.max. Reaching the wrap point is unrealistic,
            // and only simultaneously outstanding generations need to be distinct.
            generation &+= 1
            pendingGeneration = generation
            return generation
        }

        /// Accepts the newest completion exactly once and rejects stale or duplicate callbacks.
        mutating func complete(_ generation: Int) -> Bool {
            guard generation == self.generation,
                  pendingGeneration == generation else {
                return false
            }

            pendingGeneration = nil
            return true
        }

        /// Makes every issued token stale when disconnecting UIKit.
        mutating func invalidate() {
            generation &+= 1
            pendingGeneration = nil
        }
    }

    /// Returns the greatest valid vertical offset, accounting for short content and safe areas.
    static func bottomOffsetY(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        adjustedContentInset: UIEdgeInsets
    ) -> CGFloat {
        max(
            -adjustedContentInset.top,
            contentHeight - boundsHeight + adjustedContentInset.bottom
        )
    }

    /// Reports whether the current offset is close enough to the effective bottom to follow it.
    /// Clamping prevents rubber-band overscroll from being mistaken for distance from the bottom.
    static func isBottomPinned(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        contentOffsetY: CGFloat,
        adjustedContentInset: UIEdgeInsets,
        tolerance: CGFloat = 2
    ) -> Bool {
        let maximumOffsetY = bottomOffsetY(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            adjustedContentInset: adjustedContentInset
        )
        let minimumOffsetY = -adjustedContentInset.top
        let clampedContentOffsetY = min(
            max(contentOffsetY, minimumOffsetY),
            maximumOffsetY
        )
        return maximumOffsetY - clampedContentOffsetY <= tolerance
    }

    /// Measures scrollable distance from the effective bottom after clamping rubber-band offsets.
    static func distanceFromBottom(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        contentOffsetY: CGFloat,
        adjustedContentInset: UIEdgeInsets
    ) -> CGFloat {
        let maximumOffsetY = bottomOffsetY(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            adjustedContentInset: adjustedContentInset
        )
        let minimumOffsetY = -adjustedContentInset.top
        let clampedContentOffsetY = min(
            max(contentOffsetY, minimumOffsetY),
            maximumOffsetY
        )
        return max(0, maximumOffsetY - clampedContentOffsetY)
    }

    /// Shows the affordance only after the user has left at least one unobscured viewport below.
    static func shouldShowScrollDownButton(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        contentOffsetY: CGFloat,
        adjustedContentInset: UIEdgeInsets
    ) -> Bool {
        let visibleViewportHeight = max(
            0,
            boundsHeight
                - adjustedContentInset.top
                - adjustedContentInset.bottom
        )
        guard visibleViewportHeight > 0 else {
            return false
        }

        return distanceFromBottom(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            contentOffsetY: contentOffsetY,
            adjustedContentInset: adjustedContentInset
        ) >= visibleViewportHeight
    }

    /// Respects active touch interaction and Reduce Motion for explicit scroll requests.
    static func shouldAnimateScrollToBottom(
        isInteractionActive: Bool,
        isReduceMotionEnabled: Bool
    ) -> Bool {
        !isInteractionActive && !isReduceMotionEnabled
    }

    /// Returns an animation start no more than one visible viewport above the resolved bottom.
    static func boundedBottomAnimationStartOffsetY(
        previousOffsetY: CGFloat,
        bottomOffsetY: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        bottomOffsetY - min(
            max(0, viewportHeight),
            max(0, bottomOffsetY - previousOffsetY)
        )
    }

    /// Finds existing stable IDs whose rendered value or padding changed.
    /// These IDs are reconfigured in the same target snapshot instead of being deleted/reinserted.
    static func changedRowIDs(
        previousRowsByID: [DisplayedChatRow.ID: DisplayedChatRowWithPadding],
        rows: [DisplayedChatRowWithPadding]
    ) -> [DisplayedChatRow.ID] {
        rows.compactMap { row in
            guard let previousRow = previousRowsByID[row.id], previousRow != row else {
                return nil
            }
            return row.id
        }
    }

    /// Reports whether an existing turn summary changed its disclosure state.
    static func hasTurnSummaryDisclosureChange(
        from previousRows: [DisplayedChatRowWithPadding],
        to rows: [DisplayedChatRowWithPadding]
    ) -> Bool {
        let previousSummaries: [DisplayedChatRow.TurnSummary.ID: Bool] = Dictionary(
            uniqueKeysWithValues: previousRows.compactMap { row in
                guard case .turnSummary(let summary) = row.content else {
                    return nil
                }
                return (summary.id, summary.isExpanded)
            }
        )
        return rows.contains { row in
            guard case .turnSummary(let summary) = row.content,
                  let wasExpanded = previousSummaries[summary.id] else {
                return false
            }
            return wasExpanded != summary.isExpanded
        }
    }

    /// Decides whether the next bottom correction should use UIKit's native scroll animation.
    /// Diffable row animation is a separate decision; for example, summary rows may insert with a
    /// diffable animation while their bottom-offset correction remains immediate.
    static func shouldAnimateBottomFollow(
        from previousRows: [DisplayedChatRowWithPadding],
        to rows: [DisplayedChatRowWithPadding],
        isInitialContent: Bool = false,
        isFollowingBottom: Bool = true,
        isInteractionActive: Bool = false,
        isReduceMotionEnabled: Bool = false
    ) -> Bool {
        // These contexts all require an immediate correction or no correction. In particular,
        // never compete with an active touch, and never opt into motion when Reduce Motion is on.
        guard !isInitialContent,
              !rows.isEmpty,
              isFollowingBottom,
              !isInteractionActive,
              !isReduceMotionEnabled,
              previousRows != rows else {
            return false
        }

        // Summary expansion can change several row heights and identities at once.
        guard !hasTurnSummaryDisclosureChange(from: previousRows, to: rows) else {
            return false
        }

        // Removing a progress row means a working turn completed. That transition is immediate so
        // the progress removal and final layout do not combine with a second offset animation.
        let previousProgressIDs: Set<DisplayedChatRow.ID> = Set(previousRows.compactMap { row in
            guard case .turnInProgress = row.content else {
                return nil
            }
            return row.id
        })
        let progressIDs: Set<DisplayedChatRow.ID> = Set(rows.compactMap { row in
            guard case .turnInProgress = row.content else {
                return nil
            }
            return row.id
        })
        // After the exclusions above, the policy treats every remaining nonempty change—including
        // progress insertion—as append/streaming and allows animation.
        return previousProgressIDs.isSubset(of: progressIDs)
    }

    /// Reports whether a point is in a summary's expanded target without overlapping any row.
    static func isExpandedSummaryHit(
        _ location: CGPoint,
        summaryFrame: CGRect,
        visibleRowFrames: [CGRect]
    ) -> Bool {
        let didTapVisibleRow = visibleRowFrames.contains { $0.contains(location) }
        guard !didTapVisibleRow else {
            return false
        }

        return summaryFrame.insetBy(
            dx: 0,
            dy: -ChatRowLayout.summaryHitTargetExpansion
        ).contains(location)
    }

    /// Calculates the offset that preserves the first surviving pre-update anchor.
    /// Returns `nil` only when none of the captured row IDs still has layout attributes.
    static func restoredOffsetY(
        anchorItems: [ViewportAnchorItem],
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat,
        itemMinY: (DisplayedChatRow.ID) -> CGFloat?
    ) -> CGFloat? {
        for item in anchorItems {
            guard let minY = itemMinY(item.id) else {
                continue
            }

            return min(
                max(minY - item.offset, minimumOffsetY),
                maximumOffsetY
            )
        }
        return nil
    }
}

extension ChatCollectionView {
    /// Owns UIKit-only state that cannot live in SwiftUI's immutable representable value.
    ///
    /// The coordinator retains the data source, translates delegate callbacks into scroll intent,
    /// and reconciles position after asynchronous snapshots and self-sizing layout settle. It does
    /// not own chat feature state; `rows` and actions still come from SwiftUI/TCA.
    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        /// The feed uses one section; the enum gives the diffable snapshot stable section identity.
        private enum Section: Hashable {
            case chat
        }

        /// Ordered visible-row candidates captured before a viewport-preserving update.
        private struct ViewportAnchor {
            /// Top-to-bottom candidates; restoration uses the first row that survives the snapshot.
            let items: [ViewportAnchorItem]
        }

        /// Names the cell-registration type used to configure hosted SwiftUI rows.
        private typealias CellRegistration = UICollectionView.CellRegistration<
            UICollectionViewCell,
            DisplayedChatRow.ID
        >

        /// Weak back-reference used by gesture callbacks; the representable owns the view.
        private weak var collectionView: UICollectionView?

        /// The single retained diffable data source used for every render.
        private var dataSource: UICollectionViewDiffableDataSource<
            Section,
            DisplayedChatRow.ID
        >?

        /// Expands the compact summary's tappable area outside its cell bounds.
        private var expandedSummaryTapGestureRecognizer: UITapGestureRecognizer?

        /// Suppresses delegate feedback while an immediate coordinator-owned offset is changing.
        private var isApplyingCoordinatorOffset = false

        /// Suppresses scroll-policy changes while the bottom bar and content inset animate together.
        private var isAnimatingContentInset = false

        /// Rejects completions from superseded bottom-bar animations.
        private var contentInsetAnimationGeneration = 0

        /// Records correction work that could not run during a snapshot or user interaction.
        private(set) var needsScrollCorrection = false

        /// Keeps an explicit send request authoritative until changed rows are reconciled.
        private(set) var needsScrollToBottom = false

        /// Whether the next successful changed-row reconciliation consumes the send request.
        private var shouldConsumeScrollToBottomRequest = false

        /// The last row values accepted by `render`, used for idempotence and transition policy.
        private var renderedRows: [DisplayedChatRowWithPadding] = []

        /// Last explicit request consumed from SwiftUI.
        private var scrollToBottomRequest = 0

        /// Last animated button request consumed from SwiftUI.
        private var animatedScrollToBottomRequest = 0

        /// Current content lookup used when the cell registration configures a stable item ID.
        private var rowsByID: [DisplayedChatRow.ID: DisplayedChatRowWithPadding] = [:]

        /// Tracks initial placement and the user's bottom-follow preference for the current session.
        private var scrollPolicy = ScrollPolicy()

        /// One-shot intent consumed by the next valid bottom correction.
        /// A drag, inset change, immediate transition, or disconnect clears it before it can run.
        private var shouldAnimateNextBottomCorrection = false

        /// The button request that owns the viewport until its native scroll reaches the bottom.
        private var explicitBottomScrollRequest: Int?

        /// Protects reconciliation from stale diffable apply completions.
        private var snapshotApplicationState = SnapshotApplicationState()

        /// Last row that must become visible before initial placement is considered complete.
        private var initialScrollItemID: DisplayedChatRow.ID?

        /// Latest visibility callback from SwiftUI, replaced even when rows are unchanged.
        private var scrollDownButtonVisibilityChanged: @MainActor (Bool) -> Void = { _ in }

        /// Last visibility value sent to SwiftUI, preventing geometry callbacks from churning state.
        private var isScrollDownButtonVisible = false

        /// Latest action closure from SwiftUI, replaced even when the row values are unchanged.
        private var turnSummaryTapped: @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void = { _ in }

        /// Captured visible geometry used only while the user is not following the bottom.
        private var viewportAnchor: ViewportAnchor?

        /// Connects delegate-adjacent behavior and creates the retained cell/data-source graph.
        /// Called once from `makeUIView` after the collection view is configured.
        func connect(to collectionView: UICollectionView) {
            self.collectionView = collectionView

            // UIScrollView delegate callbacks own real drag/deceleration handoff. Observing the pan
            // recognizer additionally catches a touch that ends without ever becoming a drag.
            collectionView.panGestureRecognizer.addTarget(
                self,
                action: #selector(scrollPanGestureDidChange)
            )
            let expandedSummaryTapGestureRecognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(expandedSummaryTargetTapped)
            )
            expandedSummaryTapGestureRecognizer.cancelsTouchesInView = false
            expandedSummaryTapGestureRecognizer.delegate = self
            collectionView.addGestureRecognizer(expandedSummaryTapGestureRecognizer)
            self.expandedSummaryTapGestureRecognizer = expandedSummaryTapGestureRecognizer

            // Diffable identity contains only stable IDs. Mutable row values live in `rowsByID`, so
            // reconfiguration updates hosted SwiftUI content without replacing the cell identity.
            let cellRegistration = CellRegistration { [weak self] cell, _, itemID in
                guard let self, let row = rowsByID[itemID] else {
                    cell.accessibilityIdentifier = nil
                    cell.contentConfiguration = nil
                    return
                }

                cell.accessibilityIdentifier = "chat.row.\(row.id)"
                cell.contentConfiguration = UIHostingConfiguration {
                    ChatRowView(row: row.content) { [weak self] summaryID in
                        self?.turnSummaryTapped(summaryID)
                    }
                        .padding(.horizontal, ChatRowLayout.horizontalPadding)
                        .padding(.top, row.topPadding)
                        .padding(.bottom, row.bottomPadding)
                        .accessibilityElement(children: .contain)
                }
                    .margins(.all, 0)
            }

            // The data source and registration are created once. `render` only changes snapshots
            // and the row lookup, which preserves UIKit's reuse machinery across streaming updates.
            self.dataSource = UICollectionViewDiffableDataSource(
                collectionView: collectionView
            ) { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: cellRegistration,
                    for: indexPath,
                    item: itemID
                )
            }
        }

        /// Detaches callbacks and clears view-lifetime snapshot, row, and correction state.
        /// Invalidating the generation prevents an in-flight snapshot completion from touching a
        /// dismantled collection view.
        func disconnect() {
            cancelExplicitBottomScroll()
            if let collectionView {
                collectionView.panGestureRecognizer.removeTarget(
                    self,
                    action: #selector(scrollPanGestureDidChange)
                )
                stopNativeScrollAnimation(in: collectionView)
            }
            if let expandedSummaryTapGestureRecognizer {
                collectionView?.removeGestureRecognizer(expandedSummaryTapGestureRecognizer)
            }
            expandedSummaryTapGestureRecognizer = nil
            snapshotApplicationState.invalidate()
            collectionView = nil
            dataSource = nil
            needsScrollCorrection = false
            needsScrollToBottom = false
            shouldConsumeScrollToBottomRequest = false
            renderedRows = []
            rowsByID = [:]
            scrollPolicy = ScrollPolicy()
            scrollToBottomRequest = 0
            animatedScrollToBottomRequest = 0
            isApplyingCoordinatorOffset = false
            isAnimatingContentInset = false
            contentInsetAnimationGeneration &+= 1
            shouldAnimateNextBottomCorrection = false
            initialScrollItemID = nil
            scrollDownButtonVisibilityChanged = { _ in }
            isScrollDownButtonVisible = false
            viewportAnchor = nil
        }

        /// Allows the expanded-summary hit target to coexist with scrolling and row-local taps.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === expandedSummaryTapGestureRecognizer
                || otherGestureRecognizer === expandedSummaryTapGestureRecognizer
        }

        /// Applies the latest ordered rows and schedules the matching post-layout scroll correction.
        ///
        /// This is the coordinator's main state transition. It classifies scroll behavior from the
        /// old and new row values, builds one complete target snapshot, reconfigures changed stable
        /// IDs in that snapshot, and lets only its generation-safe completion reconcile geometry.
        func render(
            rows: [DisplayedChatRowWithPadding],
            animatedScrollToBottomRequest: Int = 0,
            scrollToBottomRequest: Int = 0,
            animation: Animation?,
            scrollDownButtonVisibilityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
            turnSummaryTapped: @escaping @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void,
            in collectionView: UICollectionView
        ) {
            guard let dataSource else {
                return
            }

            // The action may capture a newer Store even when the visual rows did not change.
            self.scrollDownButtonVisibilityChanged = scrollDownButtonVisibilityChanged
            self.turnSummaryTapped = turnSummaryTapped

            let shouldScrollToBottom = self.scrollToBottomRequest != scrollToBottomRequest
            let isScrollDownButtonRequest = self.animatedScrollToBottomRequest
                != animatedScrollToBottomRequest
            if shouldScrollToBottom, isScrollDownButtonRequest {
                beginExplicitBottomScroll(
                    request: animatedScrollToBottomRequest,
                    in: collectionView
                )
            }
            let shouldAnimateScrollRequest = shouldScrollToBottom
                && isScrollDownButtonRequest
                && ChatCollectionView.shouldAnimateScrollToBottom(
                    isInteractionActive: isInteracting(
                        with: collectionView,
                        shouldAllowDecelerationInterruption: true
                    ),
                    isReduceMotionEnabled: UIAccessibility.isReduceMotionEnabled
                )
            self.scrollToBottomRequest = scrollToBottomRequest
            self.animatedScrollToBottomRequest = animatedScrollToBottomRequest
            if shouldScrollToBottom {
                if !isScrollDownButtonRequest {
                    stopNativeScrollAnimation(in: collectionView)
                }
                shouldAnimateNextBottomCorrection = shouldAnimateScrollRequest
                scrollPolicy.scrollToBottomRequested()
                needsScrollToBottom = true
                shouldConsumeScrollToBottomRequest = isScrollDownButtonRequest
                viewportAnchor = nil
            }

            let previousRows = renderedRows
            guard previousRows != rows else {
                if shouldScrollToBottom {
                    reconcileScrollPosition(
                        in: collectionView,
                        shouldLayoutIfNeeded: true
                    )
                }
                return
            }

            if needsScrollToBottom {
                shouldConsumeScrollToBottomRequest = true
            }

            // Classify offset animation before replacing rendered rows. Diffable structural animation
            // is calculated later and intentionally remains independent from this choice.
            let hasDisclosureChange = ChatCollectionView.hasTurnSummaryDisclosureChange(
                from: previousRows,
                to: rows
            )
            let intent = scrollPolicy.rowsWillChange(
                hasRows: !rows.isEmpty,
                shouldPreserveViewport: hasDisclosureChange && !needsScrollToBottom
            )
            let isInitialContent = intent == .bottom(isInitial: true)
            let isInteractionActive = isInteracting(with: collectionView)
            let shouldAnimateBottom = shouldAnimateScrollRequest
                || (
                    !shouldScrollToBottom
                        && ChatCollectionView.shouldAnimateBottomFollow(
                            from: previousRows,
                            to: rows,
                            isInitialContent: isInitialContent,
                            isFollowingBottom: scrollPolicy.isFollowingBottom,
                            isInteractionActive: isInteractionActive,
                            isReduceMotionEnabled: UIAccessibility.isReduceMotionEnabled
                        )
                )

            // Any immediate transition stops active programmatic scrolling.
            if !shouldAnimateBottom {
                stopNativeScrollAnimation(in: collectionView)
            }

            // Initial placement follows a concrete last item through self-sizing layout. If rows
            // change again before it becomes visible, advance the target to the newest last item.
            if rows.isEmpty {
                initialScrollItemID = nil
                viewportAnchor = nil
            }
            if isInitialContent {
                initialScrollItemID = rows.last?.id
            } else if initialScrollItemID != nil,
                      let latestItemID = rows.last?.id {
                initialScrollItemID = latestItemID
            }

            // An unpinned feed preserves visible row geometry. Capture before applying the snapshot,
            // while the old IDs and layout attributes still describe the onscreen viewport.
            let shouldRestoreViewport = intent == .preserveViewport
            if shouldRestoreViewport, viewportAnchor == nil {
                viewportAnchor = captureViewportAnchor(in: collectionView)
            } else if case .bottom = intent {
                viewportAnchor = nil
            }

            // Update the cell-content lookup first so any cells configured during apply receive the
            // new value. Stable IDs whose values changed are reconfigured in the target snapshot.
            let previousRowsByID = rowsByID
            renderedRows = rows
            rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let currentItemIDs = dataSource.snapshot().itemIdentifiers
            let newItemIDs = rows.map(\.id)
            let hasStructuralChanges = currentItemIDs != newItemIDs
            let changedItemIDs = ChatCollectionView.changedRowIDs(
                previousRowsByID: previousRowsByID,
                rows: rows
            )

            // Every render uses one full target snapshot. This keeps item order, insertions,
            // deletions, and content reconfiguration in a single diffable transaction.
            var snapshot = NSDiffableDataSourceSnapshot<
                Section,
                DisplayedChatRow.ID
            >()
            snapshot.appendSections([.chat])
            snapshot.appendItems(newItemIDs)
            let currentItemIDSet = Set(currentItemIDs)
            snapshot.reconfigureItems(
                changedItemIDs.filter { currentItemIDSet.contains($0) }
            )

            // UIKit may finish apply callbacks after a later render. The generation guard ensures
            // only the newest completion can clear pending state or move the scroll position.
            let generation = snapshotApplicationState.begin()
            let shouldAnimateDifferences = hasStructuralChanges
                && !isInitialContent
                && animation != nil
                && !UIAccessibility.isReduceMotionEnabled

            // Store animation intent before applying. Interaction or inset changes that occur while
            // the snapshot is pending can then cancel it without the completion re-arming it.
            shouldAnimateNextBottomCorrection = shouldAnimateBottom
            dataSource.apply(
                snapshot,
                animatingDifferences: shouldAnimateDifferences
            ) { [weak self, weak collectionView] in
                guard let self,
                      let collectionView,
                      snapshotApplicationState.complete(generation) else {
                    return
                }

                // Initial placement and anchor restoration need current self-sized attributes before
                // calculating offsets. Animated bottom follow also resolves self-sizing first so its
                // destination cannot change underneath the native scroll animation.
                reconcileScrollPosition(
                    in: collectionView,
                    shouldLayoutIfNeeded: initialScrollItemID != nil
                        || shouldRestoreViewport
                        || needsScrollToBottom
                        || shouldAnimateBottom
                )
            }
        }

        /// Reconciles after bounds, content size, or adjusted-inset changes reported by the subclass.
        /// If a snapshot or interaction is active, reconciliation records deferred work instead.
        func collectionViewDidLayout(_ collectionView: UICollectionView) {
            guard !isApplyingCoordinatorOffset,
                  !isExplicitBottomScrollActive else {
                return
            }
            reconcileScrollPosition(in: collectionView)
            updateScrollDownButtonVisibility(for: collectionView)
        }

        /// Applies SwiftUI-owned safe-area insets and keeps bottom-pinned content above the bar.
        func updateContentInset(
            _ contentInset: UIEdgeInsets,
            animationDuration: TimeInterval?,
            in collectionView: UICollectionView
        ) {
            guard collectionView.contentInset != contentInset else {
                return
            }

            stopNativeScrollAnimation(in: collectionView)
            let shouldMaintainBottom = scrollPolicy.hasDisplayedContent
                && (
                    scrollPolicy.isFollowingBottom
                        || ChatCollectionView.isBottomPinned(
                            contentHeight: collectionView.contentSize.height,
                            boundsHeight: collectionView.bounds.height,
                            contentOffsetY: collectionView.contentOffset.y,
                            adjustedContentInset: collectionView.adjustedContentInset
                        )
                )
                && !isInteracting(with: collectionView)
            if shouldMaintainBottom {
                scrollPolicy.isFollowingBottom = true
                viewportAnchor = nil
            }

            let update = { [weak self, weak collectionView] in
                guard let self, let collectionView else {
                    return
                }

                performCoordinatorOffsetChange {
                    collectionView.contentInset = contentInset
                    collectionView.verticalScrollIndicatorInsets = contentInset
                    guard shouldMaintainBottom else {
                        return
                    }

                    collectionView.contentOffset.y = ChatCollectionView.bottomOffsetY(
                        contentHeight: collectionView.contentSize.height,
                        boundsHeight: collectionView.bounds.height,
                        adjustedContentInset: collectionView.adjustedContentInset
                    )
                }
            }

            guard let animationDuration,
                  animationDuration > 0,
                  !UIAccessibility.isReduceMotionEnabled,
                  !isInteracting(with: collectionView) else {
                contentInsetAnimationGeneration &+= 1
                isAnimatingContentInset = false
                update()
                if isInteracting(with: collectionView) {
                    needsScrollCorrection = true
                }
                return
            }

            contentInsetAnimationGeneration &+= 1
            let generation = contentInsetAnimationGeneration
            isAnimatingContentInset = true
            UIView.animate(
                withDuration: animationDuration,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
            ) {
                update()
            } completion: { [weak self, weak collectionView] _ in
                guard let self,
                      let collectionView,
                      generation == contentInsetAnimationGeneration else {
                    return
                }

                isAnimatingContentInset = false
                reconcileScrollPosition(in: collectionView)
            }
        }

        /// Drains correction after a stationary touch ends without becoming a UIScrollView drag.
        /// Real drag → deceleration transitions remain owned by the scroll-view delegate callbacks.
        @objc func scrollPanGestureDidChange(
            _ gestureRecognizer: UIPanGestureRecognizer
        ) {
            switch gestureRecognizer.state {
            case .ended, .cancelled, .failed:
                guard let collectionView else {
                    return
                }
                if collectionView.isDragging || collectionView.isDecelerating {
                    // The pan can end before UIScrollView finishes its state transition. Preserve the
                    // request; `scrollViewDidEndDragging` or `scrollViewDidEndDecelerating` drains it.
                    needsScrollCorrection = true
                    return
                }
                scrollingEnded(collectionView)
            case .possible, .began, .changed:
                return
            @unknown default:
                return
            }
        }

        /// Handles taps in the extra vertical hit area around a compact turn-summary cell.
        /// Taps inside the actual row are left to `TurnSummaryRowView`, avoiding duplicate actions.
        @objc private func expandedSummaryTargetTapped(
            _ gestureRecognizer: UITapGestureRecognizer
        ) {
            guard gestureRecognizer.state == .ended,
                  let collectionView,
                  let dataSource else {
                return
            }

            let location = gestureRecognizer.location(in: collectionView)
            // Only visible rows can contain the touch, so restrict hit-testing to them.
            let visibleAttributes = collectionView.indexPathsForVisibleItems.compactMap {
                collectionView.layoutAttributesForItem(at: $0)
            }
            let visibleRowFrames = visibleAttributes.map(\.frame)
            for attributes in visibleAttributes {
                let indexPath = attributes.indexPath
                guard let itemID = dataSource.itemIdentifier(for: indexPath),
                      let row = rowsByID[itemID],
                      case let .turnSummary(summary) = row.content else {
                    continue
                }

                let rowFrame = attributes.frame
                // Accept only the deliberately expanded area without stealing another row's tap.
                guard ChatCollectionView.isExpandedSummaryHit(
                    location,
                    summaryFrame: rowFrame,
                    visibleRowFrames: visibleRowFrames
                ) else {
                    continue
                }

                turnSummaryTapped(summary.id)
                return
            }
        }

        /// Cancels native bottom-follow when the user begins dragging.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            cancelExplicitBottomScroll()
            if let collectionView = scrollView as? UICollectionView {
                stopNativeScrollAnimation(in: collectionView)
            }
            initialScrollItemID = nil
            needsScrollToBottom = false
            shouldConsumeScrollToBottomRequest = false
            viewportAnchor = nil
        }

        /// Updates bottom-follow intent from user-driven scrolling while ignoring coordinator motion.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateScrollDownButtonVisibility(for: scrollView)

            // Initial positioning, immediate coordinator offsets, and UIKit's own animation generate
            // delegate callbacks that must not be interpreted as the user leaving the bottom.
            guard initialScrollItemID == nil,
                  !isApplyingCoordinatorOffset,
                  !isAnimatingContentInset,
                  !isExplicitBottomScrollActive,
                  !needsScrollToBottom,
                  !scrollView.isScrollAnimating else {
                return
            }

            // Preserve pre-update geometry until a blocked snapshot correction can be restored.
            if viewportAnchor != nil,
               snapshotApplicationState.isPending || needsScrollCorrection {
                return
            }

            updateBottomFollowState(for: scrollView)
            viewportAnchor = nil
        }

        /// Reconciles when a drag ends immediately; decelerating drags defer to the later callback.
        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate shouldDecelerate: Bool
        ) {
            guard !shouldDecelerate else {
                return
            }

            scrollingEnded(scrollView)
        }

        /// Reconciles after the final inertial offset is known.
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scrollingEnded(scrollView)
        }

        /// Reconciles final geometry after UIKit completes an animated bottom correction.
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            if let request = explicitBottomScrollRequest,
               let collectionView = scrollView as? UICollectionView {
                finishExplicitBottomScroll(
                    request: request,
                    in: collectionView
                )
                return
            }

            scrollingEnded(
                scrollView,
                shouldUpdateVisibilityDuringAnimation: true
            )
        }

        /// Reconciles after scroll-to-top settles.
        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            scrollingEnded(scrollView)
        }

        /// Consolidates all interaction/animation completion callbacks into one settled-state path.
        private func scrollingEnded(
            _ scrollView: UIScrollView,
            shouldUpdateVisibilityDuringAnimation: Bool = false
        ) {
            guard let collectionView = scrollView as? UICollectionView else {
                return
            }
            guard !isApplyingCoordinatorOffset else {
                return
            }
            // A callback may arrive while another phase of the same interaction is still active.
            // Keep the correction pending until tracking, dragging, and deceleration are all false.
            guard !isInteracting(with: collectionView) else {
                needsScrollCorrection = true
                return
            }
            guard !isExplicitBottomScrollActive else {
                return
            }

            updateScrollDownButtonVisibility(
                for: collectionView,
                shouldUpdateDuringAnimation:
                    shouldUpdateVisibilityDuringAnimation
            )

            // Initial placement has not established user intent yet. Finish it before deriving
            // bottom-follow state from the current offset.
            if initialScrollItemID != nil || needsScrollToBottom {
                reconcileScrollPosition(
                    in: collectionView,
                    shouldLayoutIfNeeded: true
                )
                return
            }

            if viewportAnchor != nil,
               snapshotApplicationState.isPending || needsScrollCorrection {
                reconcileScrollPosition(
                    in: collectionView,
                    shouldLayoutIfNeeded: true
                )
                return
            }

            // Once scrolling settles, its current offset becomes authoritative. Capture a fresh
            // anchor only when that settled offset is away from the bottom.
            updateBottomFollowState(for: scrollView)
            viewportAnchor = scrollPolicy.isFollowingBottom
                ? nil
                : captureViewportAnchor(in: collectionView)
            reconcileScrollPosition(
                in: collectionView,
                shouldLayoutIfNeeded: viewportAnchor != nil
            )
        }

        /// Reconciles scroll position once snapshot and interaction blockers clear.
        ///
        /// A blocked attempt leaves `needsScrollCorrection` set. Successful reconciliation clears
        /// it here; session replacement and disconnect discard it separately.
        private func reconcileScrollPosition(
            in collectionView: UICollectionView,
            shouldLayoutIfNeeded: Bool = false
        ) {
            guard !isExplicitBottomScrollActive || needsScrollToBottom else {
                needsScrollCorrection = true
                return
            }

            guard !snapshotApplicationState.isPending,
                  !isAnimatingContentInset,
                  !isInteracting(
                      with: collectionView,
                      shouldAllowDecelerationInterruption:
                          isExplicitBottomScrollActive
                  ) else {
                needsScrollCorrection = true
                return
            }

            needsScrollCorrection = false

            // Self-sizing rows must expose their current attributes before initial placement or anchor
            // restoration calculates an offset. The reentrancy guard prevents this synchronous
            // layout from changing bottom-follow intent through `scrollViewDidScroll`.
            if shouldLayoutIfNeeded {
                performCoordinatorOffsetChange {
                    collectionView.layoutIfNeeded()
                }
            }

            if needsScrollToBottom {
                scrollPolicy.scrollToBottomRequested()
                viewportAnchor = nil
            }

            // Initial item placement handles long content efficiently; the following correction
            // also handles short content, whose true bottom may be the negative top inset.
            scrollToInitialItemIfNeeded(in: collectionView)
            correctScrollPosition(
                in: collectionView,
                shouldAllowDecelerationInterruption:
                    isExplicitBottomScrollActive
            )

            if shouldConsumeScrollToBottomRequest {
                needsScrollToBottom = false
                shouldConsumeScrollToBottomRequest = false
            }

            // Keep the initial target until UIKit confirms that it is both visible and bottom-pinned.
            // Estimated self-sizing can require more than one layout reconciliation to reach this.
            if let initialScrollItemID,
               let dataSource,
               let indexPath = dataSource.indexPath(for: initialScrollItemID),
               collectionView.indexPathsForVisibleItems.contains(indexPath),
               ChatCollectionView.isBottomPinned(
                   contentHeight: collectionView.contentSize.height,
                   boundsHeight: collectionView.bounds.height,
                   contentOffsetY: collectionView.contentOffset.y,
                   adjustedContentInset: collectionView.adjustedContentInset
               ) {
                self.initialScrollItemID = nil
                scrollPolicy.isFollowingBottom = true
            }
        }

        /// Applies either bottom-follow or viewport restoration according to the current policy.
        private func correctScrollPosition(
            in collectionView: UICollectionView,
            shouldAllowDecelerationInterruption: Bool = false
        ) {
            guard !isInteracting(
                with: collectionView,
                shouldAllowDecelerationInterruption:
                    shouldAllowDecelerationInterruption
            ) else {
                needsScrollCorrection = true
                return
            }

            if scrollPolicy.isFollowingBottom, scrollPolicy.hasDisplayedContent {
                let shouldAnimate = shouldAnimateNextBottomCorrection
                shouldAnimateNextBottomCorrection = false
                if isExplicitBottomScrollActive {
                    scrollExplicitlyToBottom(
                        animated: shouldAnimate,
                        in: collectionView
                    )
                    return
                }

                // Layout can change repeatedly during a native animation. Do not replace that
                // animation unless a newer row update supplied a fresh one-shot animation intent.
                if collectionView.isScrollAnimating,
                   !shouldAnimate {
                    return
                }

                let bottomOffsetY = ChatCollectionView.bottomOffsetY(
                    contentHeight: collectionView.contentSize.height,
                    boundsHeight: collectionView.bounds.height,
                    adjustedContentInset: collectionView.adjustedContentInset
                )

                // Consume before setting the offset so delegate/layout reentrancy cannot reuse the
                // request for a second animation.
                if shouldAnimate,
                   animateFinalViewportToLastItem(in: collectionView) {
                    return
                }
                setContentOffsetY(
                    bottomOffsetY,
                    animated: false,
                    in: collectionView
                )
            } else if let viewportAnchor {
                // Viewport preservation is always immediate: the user should not see compensation
                // for rows inserted, removed, expanded, or resized outside the viewport.
                stopNativeScrollAnimation(in: collectionView)
                restore(viewportAnchor, in: collectionView)
            }
        }

        /// Clears the one-shot intent and stops an active programmatic content-offset animation.
        private func stopNativeScrollAnimation(in collectionView: UICollectionView) {
            shouldAnimateNextBottomCorrection = false
            guard !isExplicitBottomScrollActive else {
                return
            }
            if collectionView.isScrollAnimating {
                performCoordinatorOffsetChange {
                    collectionView.stopScrollingAndZooming()
                }
            }
        }

        /// Whether the button currently owns all viewport correction.
        private var isExplicitBottomScrollActive: Bool {
            explicitBottomScrollRequest != nil
        }

        /// Replaces native inertia immediately and makes the button the viewport owner.
        private func beginExplicitBottomScroll(
            request: Int,
            in collectionView: UICollectionView
        ) {
            let interruptedOffset = collectionView.contentOffset
            cancelExplicitBottomScroll()
            explicitBottomScrollRequest = request
            performCoordinatorOffsetChange {
                collectionView.stopScrollingAndZooming()
                collectionView.setContentOffset(interruptedOffset, animated: false)
            }
        }

        /// Stops only the button-owned animation; ordinary follow behavior remains independent.
        private func cancelExplicitBottomScroll() {
            explicitBottomScrollRequest = nil
        }

        /// Resolves the real bottom, then lets UIKit animate the final laid-out viewport.
        private func scrollExplicitlyToBottom(
            animated: Bool,
            in collectionView: UICollectionView
        ) {
            guard let request = explicitBottomScrollRequest else {
                return
            }
            guard animated,
                  let bottomOffsetY = prepareFinalViewport(in: collectionView),
                  abs(collectionView.contentOffset.y - bottomOffsetY) > 0.5 else {
                finishExplicitBottomScroll(
                    request: request,
                    in: collectionView
                )
                return
            }

            setContentOffsetY(
                bottomOffsetY,
                animated: true,
                in: collectionView
            )
        }

        /// Performs one final concrete-item correction after the bounded animation completes.
        func finishExplicitBottomScroll(
            request: Int?,
            in collectionView: UICollectionView
        ) {
            guard let request,
                  explicitBottomScrollRequest == request else {
                return
            }

            positionAtConcreteBottom(in: collectionView)
            explicitBottomScrollRequest = nil
            needsScrollCorrection = false
            updateBottomFollowState(for: collectionView)
            updateScrollDownButtonVisibility(
                for: collectionView,
                shouldUpdateDuringAnimation: true
            )
        }

        /// Resolves the concrete final item and exact inset-adjusted bottom synchronously.
        private func positionAtConcreteBottom(
            in collectionView: UICollectionView
        ) {
            performCoordinatorOffsetChange {
                if let indexPath = lastItemIndexPath() {
                    collectionView.scrollToItem(
                        at: indexPath,
                        at: .bottom,
                        animated: false
                    )
                }
                collectionView.layoutIfNeeded()
                collectionView.setContentOffset(
                    CGPoint(
                        x: collectionView.contentOffset.x,
                        y: ChatCollectionView.bottomOffsetY(
                            contentHeight: collectionView.contentSize.height,
                            boundsHeight: collectionView.bounds.height,
                            adjustedContentInset: collectionView.adjustedContentInset
                        )
                    ),
                    animated: false
                )
            }
        }

        /// Uses a concrete item to establish initial visibility after the snapshot contains it.
        private func scrollToInitialItemIfNeeded(
            in collectionView: UICollectionView
        ) {
            guard !isInteracting(with: collectionView),
                  let initialScrollItemID,
                  let dataSource,
                  let indexPath = dataSource.indexPath(for: initialScrollItemID) else {
                return
            }

            // `scrollToItem` avoids guessing through estimated heights. The generic bottom
            // correction that follows supplies exact short-content and inset behavior.
            performCoordinatorOffsetChange {
                collectionView.scrollToItem(
                    at: indexPath,
                    at: .bottom,
                    animated: false
                )
                collectionView.layoutIfNeeded()
            }
        }

        /// Resolves a stable final item, then animates only the last laid-out viewport.
        ///
        /// Animating across a very long estimated self-sizing layout makes UIKit size every
        /// intervening page and can trip its collection-view feedback-loop guard. The synchronous
        /// jump occurs before the next display pass; users see the bounded final animation.
        private func animateFinalViewportToLastItem(
            in collectionView: UICollectionView
        ) -> Bool {
            guard let bottomOffsetY = prepareFinalViewport(in: collectionView) else {
                return false
            }

            setContentOffsetY(
                bottomOffsetY,
                animated: true,
                in: collectionView
            )
            return true
        }

        /// Jumps to the concrete final item and returns the resolved bottom for a bounded animation.
        private func prepareFinalViewport(
            in collectionView: UICollectionView
        ) -> CGFloat? {
            guard let indexPath = lastItemIndexPath() else {
                return nil
            }

            let previousOffsetY = collectionView.contentOffset.y
            performCoordinatorOffsetChange {
                collectionView.scrollToItem(
                    at: indexPath,
                    at: .bottom,
                    animated: false
                )
                collectionView.layoutIfNeeded()

                let bottomOffsetY = ChatCollectionView.bottomOffsetY(
                    contentHeight: collectionView.contentSize.height,
                    boundsHeight: collectionView.bounds.height,
                    adjustedContentInset: collectionView.adjustedContentInset
                )
                let viewportHeight = max(
                    0,
                    collectionView.bounds.height
                        - collectionView.adjustedContentInset.top
                        - collectionView.adjustedContentInset.bottom
                )
                collectionView.contentOffset.y =
                    ChatCollectionView.boundedBottomAnimationStartOffsetY(
                        previousOffsetY: previousOffsetY,
                        bottomOffsetY: bottomOffsetY,
                        viewportHeight: viewportHeight
                    )
            }

            return ChatCollectionView.bottomOffsetY(
                contentHeight: collectionView.contentSize.height,
                boundsHeight: collectionView.bounds.height,
                adjustedContentInset: collectionView.adjustedContentInset
            )
        }

        /// Returns the current final item's stable diffable index path.
        private func lastItemIndexPath() -> IndexPath? {
            guard let itemID = renderedRows.last?.id,
                  let dataSource else {
                return nil
            }
            return dataSource.indexPath(for: itemID)
        }

        /// Captures visible row candidates and their exact intra-viewport offsets before an update.
        private func captureViewportAnchor(
            in collectionView: UICollectionView
        ) -> ViewportAnchor? {
            guard let dataSource else {
                return nil
            }

            let contentOffsetY = collectionView.contentOffset.y
            // Exclude cells that are technically visible only beneath the adjusted top inset.
            let readableViewportTop = contentOffsetY
                + collectionView.adjustedContentInset.top
            let items = collectionView.indexPathsForVisibleItems
                .compactMap { collectionView.layoutAttributesForItem(at: $0) }
                .filter { $0.frame.maxY >= readableViewportTop }
                .sorted { $0.frame.minY < $1.frame.minY }
                .compactMap { attributes -> ViewportAnchorItem? in
                    guard let itemID = dataSource.itemIdentifier(
                        for: attributes.indexPath
                    ) else {
                        return nil
                    }

                    return ViewportAnchorItem(
                        id: itemID,
                        offset: attributes.frame.minY - contentOffsetY
                    )
                }
            guard !items.isEmpty else {
                return nil
            }

            return ViewportAnchor(items: items)
        }

        /// Restores the first captured row that survived the snapshot to its previous visual offset.
        private func restore(
            _ anchor: ViewportAnchor,
            in collectionView: UICollectionView
        ) {
            guard let dataSource else {
                return
            }

            // Clamp restoration into the new scrollable range because deletion or size changes can
            // make the old visual offset impossible.
            let minimumOffsetY = -collectionView.adjustedContentInset.top
            let maximumOffsetY = ChatCollectionView.bottomOffsetY(
                contentHeight: collectionView.contentSize.height,
                boundsHeight: collectionView.bounds.height,
                adjustedContentInset: collectionView.adjustedContentInset
            )
            let offsetY = ChatCollectionView.restoredOffsetY(
                anchorItems: anchor.items,
                minimumOffsetY: minimumOffsetY,
                maximumOffsetY: maximumOffsetY
            ) { itemID in
                guard let indexPath = dataSource.indexPath(for: itemID),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                    return nil
                }

                return attributes.frame.minY
            }
            guard let offsetY else {
                // No captured anchor currently has usable layout attributes. Fall back to
                // geometry-derived bottom-follow state instead of guessing from content-height delta.
                viewportAnchor = nil
                updateBottomFollowState(for: collectionView)
                return
            }
            setContentOffsetY(offsetY, animated: false, in: collectionView)
            updateBottomFollowState(for: collectionView)
        }

        /// Derives the user's future follow/preserve policy from the collection's current geometry.
        private func updateBottomFollowState(for scrollView: UIScrollView) {
            scrollPolicy.isFollowingBottom = ChatCollectionView.isBottomPinned(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                contentOffsetY: scrollView.contentOffset.y,
                adjustedContentInset: scrollView.adjustedContentInset
            )
            if scrollPolicy.isFollowingBottom {
                viewportAnchor = nil
            }
        }

        /// Sends threshold crossings to SwiftUI without reacting to coordinator-owned animation.
        private func updateScrollDownButtonVisibility(
            for scrollView: UIScrollView,
            shouldUpdateDuringAnimation: Bool = false
        ) {
            guard !isApplyingCoordinatorOffset,
                  shouldUpdateDuringAnimation || !scrollView.isScrollAnimating else {
                return
            }

            let shouldShowButton = ChatCollectionView.shouldShowScrollDownButton(
                contentHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                contentOffsetY: scrollView.contentOffset.y,
                adjustedContentInset: scrollView.adjustedContentInset
            )
            guard shouldShowButton != isScrollDownButtonVisible else {
                return
            }

            isScrollDownButtonVisible = shouldShowButton
            scrollDownButtonVisibilityChanged(shouldShowButton)
        }

        /// Returns whether a touch or non-interruptible deceleration blocks correction.
        private func isInteracting(
            with scrollView: UIScrollView,
            shouldAllowDecelerationInterruption: Bool = false
        ) -> Bool {
            scrollView.isTracking
                || scrollView.isDragging
                || (
                    scrollView.isDecelerating
                        && !shouldAllowDecelerationInterruption
                )
        }

        /// Marks synchronous coordinator-owned geometry work so callbacks do not look user-driven.
        /// The previous value is restored to make nested coordinator operations safe.
        private func performCoordinatorOffsetChange(
            _ operation: () -> Void
        ) {
            let wasApplyingCoordinatorOffset = isApplyingCoordinatorOffset
            isApplyingCoordinatorOffset = true
            defer { isApplyingCoordinatorOffset = wasApplyingCoordinatorOffset }
            operation()
        }

        /// Moves to a vertical offset only when the geometry differs meaningfully.
        /// Animated calls are left to UIKit; immediate calls use the reentrancy guard above.
        private func setContentOffsetY(
            _ offsetY: CGFloat,
            animated: Bool,
            in collectionView: UICollectionView
        ) {
            guard abs(collectionView.contentOffset.y - offsetY) > 0.5 else {
                return
            }

            let setContentOffset = {
                collectionView.setContentOffset(
                    CGPoint(x: collectionView.contentOffset.x, y: offsetY),
                    animated: animated
                )
            }
            if animated {
                // Do not set the immediate reentrancy flag: UIKit's active-animation state is the
                // source of truth used by `scrollViewDidScroll` for these callbacks.
                setContentOffset()
            } else {
                stopNativeScrollAnimation(in: collectionView)
                performCoordinatorOffsetChange {
                    setContentOffset()
                }
            }
        }
    }
}

extension ChatCollectionView {
    /// Reports only geometry changes that can alter bottom or viewport-anchor calculations.
    /// UIKit exposes `layoutSubviews`, but not one consolidated callback for bounds, content size,
    /// and adjusted-inset changes, so the coordinator cannot rely on the scroll delegate alone.
    final class LayoutObservingCollectionView: UICollectionView {
        /// Invoked after a relevant layout pass; assigned and cleared by the representable.
        var layoutDidChange: (@MainActor (UICollectionView) -> Void)?

        /// Last reported viewport size, used to ignore unrelated layout passes.
        private var previousBoundsSize = CGSize.zero

        /// Last reported laid-out content size, including self-sizing row changes.
        private var previousContentSize = CGSize.zero

        /// Last reported effective inset, including safe-area and system adjustments.
        private var previousAdjustedContentInset = UIEdgeInsets.zero

        /// Filters repeated UIKit layout passes and reports only actual scroll-geometry changes.
        override func layoutSubviews() {
            super.layoutSubviews()

            let hasLayoutChange = bounds.size != previousBoundsSize
                || contentSize != previousContentSize
                || adjustedContentInset != previousAdjustedContentInset
            guard hasLayoutChange else {
                return
            }

            previousBoundsSize = bounds.size
            previousContentSize = contentSize
            previousAdjustedContentInset = adjustedContentInset
            layoutDidChange?(self)
        }
    }
}

/// Selects the existing SwiftUI presentation for a collection-view row value.
/// `UIHostingConfiguration` creates this view inside a reusable UIKit cell.
struct ChatRowView: View {
    /// The immutable row value rendered by this hosted view.
    let row: DisplayedChatRow

    /// Routes summary disclosure back through the representable to feature state.
    let turnSummaryTapped: @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void

    /// Maps each row case to its existing SwiftUI presentation.
    var body: some View {
        switch row {
        case .humanMessage(let message):
            HumanMessageRowView(row: message)
        case .optimisticMessage(let message):
            HumanMessageRowView(optimisticMessage: message)
        case let .assistantTextChunk(_, chunk, isMostRecentTextInTurn):
            AssistantMessageTextView(
                chunk: chunk,
                isMostRecentTextInTurn: isMostRecentTextInTurn
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .assistantThinking(_, let content):
            ThinkingRowView(content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .assistantToolCall(_, let toolCall):
            ToolCallRowView(toolCall: toolCall)
                .foregroundStyle(.theme(.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .assistantError(_, let message):
            AssistantErrorMessageView(errorMessage: message)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .turnInProgress(let row):
            TurnInProgressView(row: row)
        case .turnSummary(let summary):
            TurnSummaryRowView(summary: summary) {
                turnSummaryTapped(summary.id)
            }
        case .turnFooter(let footer):
            TurnCompletedFooterRowView(footer: footer)
        }
    }
}
