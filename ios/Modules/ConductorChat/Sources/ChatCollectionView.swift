//
//  ChatCollectionView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/14/26.
//

import ConductorDesign
import SwiftUI
import UIKit

/// SwiftUI still owns the ordered row values and actions. The collection view owns cell reuse,
/// self-sizing layout, diffable updates, and transient scroll interaction.
@MainActor
struct ChatCollectionView: UIViewRepresentable {
    let sessionID: String
    let rows: [DisplayedChatRowWithPadding]

    /// Retrieved from GeometryProxy
    let safeAreaInsets: EdgeInsets
    let turnSummaryTapped: @MainActor (DisplayedChatRow.TurnSummary.ID) -> Void
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.accessibilityIdentifier = "chat.scroll"
        collectionView.delegate = context.coordinator
        return collectionView
    }

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
    /// Owns UIKit-only state that cannot live in SwiftUI's immutable representable value.
    ///
    /// The coordinator retains the data source, translates delegate callbacks into scroll intent,
    /// and reconciles position after asynchronous snapshots and self-sizing layout settle. It does
    /// not own chat feature state; `rows` and actions still come from SwiftUI/TCA.

        /// The single retained diffable data source used for every render.
        private var dataSource: UICollectionViewDiffableDataSource<
            Section,
            DisplayedChatRow.ID
        >?
