# Modern collection views

## Mental model

| SwiftUI | UIKit |
| --- | --- |
| `ForEach` identity | Diffable item identifier |
| `LazyVStack` | Collection layout plus reusable cells |
| A changed value invalidates a view | A snapshot or item reconfiguration updates presentation |
| Row `View` | Cell content configuration |
| `onAppear` | No exact equivalent; use collection visibility callbacks |

Keep these layers separate:

1. Let the feature own ordered row values and actions.
2. Let the diffable snapshot describe visible identity and order.
3. Let the layout describe geometry.
4. Let the cell registration turn an identifier into current content.

## Default feed recipe

- Use `UICollectionViewDiffableDataSource<SectionID, ItemID>` with stable identifiers only.
- Retain each `UICollectionView.CellRegistration` for the collection view's lifetime. Each registration has its own reuse queue; do not construct registrations in a cell provider or render method.
- For a custom vertical feed, use one full-width item per full-width group, give both an estimated height, and set `section.interGroupSpacing` to the product spacing.
- Set `UIHostingConfiguration` margins to zero when SwiftUI already owns row padding. Avoid double-counting cell margins, section insets, and row padding.
- Prefer automatic self-sizing. Add manual invalidation or sizing code only after reproducing and measuring a sizing failure.
- Keep cell configuration cheap and idempotent. Parse and normalize data before it reaches the cell provider.

Collection-view list configuration is a good default for standard list affordances, separators, accessories, and swipe actions. It is not automatically the right choice for a bespoke chat surface with exact spacing and backgrounds. `UICollectionViewFlowLayout` also remains valid when it expresses the layout more simply.

## Identity and updates

Use an immutable row ID as the item identifier. Do not hash mutable text, progress, expansion state, or status into diffable identity; doing so turns an update into a delete and insert.

Classify every render:

- **Structure changed:** build and apply a snapshot containing the new section and item order.
- **Only existing content changed:** update the current row lookup, call `reconfigureItems` for changed identifiers on a snapshot, and apply it.
- **A stable observable row model already exists:** allow hosted SwiftUI to observe it directly, but do not introduce reference semantics only to avoid reconfiguration.

Do not mix diffable ownership with ad hoc `performBatchUpdates` mutations. Do not call `reloadData` for a streaming row. Coalesce extremely frequent updates only when measurement shows snapshot or layout work missing frame deadlines.

## Reuse is not visibility

The cell-registration closure may run before display and may run again for reconfiguration. Prefetch callbacks predict likely need; they do not mean the row appeared. Use `collectionView(_:willDisplay:forItemAt:)` and `collectionView(_:didEndDisplaying:forItemAt:)` for visibility-sensitive behavior, and keep those callbacks idempotent.

Store durable state by item ID outside cells. Never rely on a cell instance to retain expansion, loading, selection, or streaming state across reuse.
