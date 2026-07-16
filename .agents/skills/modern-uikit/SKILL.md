---
name: modern-uikit
description: Teach and guide modern UIKit design, implementation, debugging, review, and performance validation for Swift engineers who primarily know SwiftUI. Use for UICollectionView or UITableView work, diffable data sources, cell registrations and configurations, UIHostingConfiguration, SwiftUI/UIKit representable bridges, self-sizing cells, scroll-position behavior, UIKit animation, accessibility, and MainActor or Swift concurrency questions. Prefer APIs available in the repository's current Xcode and deployment target, and use UIKit only for the surface that needs it.
---

# Modern UIKit

Use UIKit as a narrow implementation tool while retaining SwiftUI for declarative content and application structure. Teach through SwiftUI analogies, small checkpoints, and code the user can own.

## Start with constraints

1. Read the repository's `AGENTS.md` files and inspect the existing feature before recommending a pattern.
2. Confirm Xcode, SDK, deployment target, Swift language mode, and strict-concurrency settings locally.
3. Treat the current repository constraints as Xcode 26.5, iOS 26, and Swift 6 until the files or toolchain say otherwise.
4. Treat WWDC26 sessions as iOS 27/Xcode 27 material. Use their explanations when helpful, but do not copy their APIs without verifying availability in the active SDK.
5. Preserve teaching-first collaboration. Explain or provide a practice checkpoint unless the user explicitly asks for implementation.

## Choose the smallest UIKit boundary

- Prefer `UICollectionView` for a dynamic, long, or frequently updated feed. Keep `UITableView` when an existing table already satisfies the requirement.
- Prefer `UIViewRepresentable` for one bare UIKit view. Use `UIViewControllerRepresentable` when view-controller lifecycle, containment, or controller-owned coordination is genuinely required.
- Prefer a simple full-width compositional layout for a bespoke feed. Use collection-view list configuration only when its list appearance and behaviors are wanted.
- Keep feature state, navigation, and row rendering in SwiftUI/TCA. Let UIKit own reuse, layout, content offsets, and transient scroll interaction.
- Avoid introducing a generic collection framework, protocol layer, or new observable model solely for the bridge.

Read [modern-collection-views.md](references/modern-collection-views.md) before designing a collection or table implementation. Read [swiftui-interop.md](references/swiftui-interop.md) whenever SwiftUI content crosses the UIKit boundary.

## Build in this order

1. Define stable, immutable section and item identifiers. Keep mutable row content outside diffable identity.
2. Define the layout and exact ownership of spacing, margins, backgrounds, and safe-area behavior.
3. Create one retained diffable data source and one retained cell registration per cell kind.
4. Host existing SwiftUI rows with `UIHostingConfiguration` and pass required values and actions explicitly.
5. Apply snapshots for structural changes. Reconfigure existing identifiers for content-only changes such as streaming.
6. Make the representable update method idempotent; create UIKit objects once and render new input into them.
7. Encode the scroll contract explicitly before adding scroll calls.
8. Keep UIKit access on `@MainActor` and keep expensive parsing, networking, and persistence outside cell configuration.
9. Preserve accessibility semantics and identifiers across the bridge.

Do not use manual data-source bookkeeping, string reuse identifiers, registrations created during updates, `reloadData` for streaming, manual row-height calculation, per-cell `UIHostingController` containment, inverted collection-view transforms, timing retries, or detached tasks that mutate UIKit.

## Specify scrolling as behavior

Define initial placement, short-content alignment, bottom-pinned tolerance, streaming growth, append and prepend behavior, user drag/deceleration, updates above the viewport, keyboard/inset changes, animation interruption, and content replacement. Do not treat cell configuration or prefetch as visibility.

Read [scroll-semantics.md](references/scroll-semantics.md) for any chat, timeline, anchoring, programmatic scrolling, or visibility task.

## Validate before claiming improvement

Build and behavior-test the smallest vertical slice first. Compare the old and new implementations with identical data, device, actions, accessibility identifiers, and update cadence. Use simulator recordings for parity, but require matched Instruments evidence—preferably on a physical device and in a release-like build—before claiming a performance win.

Read [verification.md](references/verification.md) before planning parity tests or making performance claims. Read [sources.md](references/sources.md) when checking API provenance, availability, or newer WWDC guidance.
