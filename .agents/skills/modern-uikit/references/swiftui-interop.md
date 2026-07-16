# SwiftUI interoperability

## Select the bridge

Use `UIViewRepresentable` when the UIKit surface is one self-contained view such as a collection view. Use `UIViewControllerRepresentable` when a controller must own containment, lifecycle hooks, child controllers, or broader coordination. Do not add a controller merely because UIKit is involved.

Treat the representable as an adapter:

- Create the UIKit object graph once in `makeUIView` or `makeUIViewController`.
- Render new immutable input in `updateUIView` or `updateUIViewController`.
- Make every update safe to repeat.
- Use a coordinator only for delegate callbacks or state that must bridge back to SwiftUI; do not turn it into a second feature model.
- Update stored action closures when SwiftUI supplies new ones so UIKit does not retain stale captures.
- Reset controller-owned transient state explicitly when the represented content identity changes.

## Host SwiftUI rows

Prefer `UIHostingConfiguration` for SwiftUI inside collection or table cells. It is a content configuration, participates in cell state updates, and self-sizes without manually embedding a `UIHostingController` per cell.

Configure the cell from the current row value and explicit actions. Pass custom environment dependencies explicitly when the UIKit-created hosting configuration cannot reliably inherit them from the outer SwiftUI hierarchy. Use `.margins(.all, 0)` when the existing row already owns its spacing.

Keep the feature and TCA store above the bridge. Prefer a small render input—ordered rows, revision or changed IDs, content identity, and action closures—over mirroring the entire feature state in UIKit.

## Divide animation ownership

- Let diffable data source own structural insert, delete, and move animation.
- Let hosted SwiftUI views own animation internal to one row.
- Choose programmatic scroll animation explicitly in UIKit.
- Do not assume an outer SwiftUI `withAnimation` transaction automatically governs a diffable update or UIKit content-offset animation.
- Respect Reduce Motion and verify the combined result; two individually reasonable animation systems can still produce a double animation.

## Concurrency

Keep the representable, UIKit owner, data source, delegate callbacks, snapshot application, and scroll mutations on `@MainActor`. Pass immutable `Sendable` input into background work, then return the result to the main actor. Do not use `@unchecked Sendable` to move UIKit objects across actors.

Cancel asynchronous work by item ID or owner lifetime rather than by cell lifetime alone. Re-check identity before applying late results to a reused cell.

## Accessibility

Retain accessibility labels, values, traits, actions, and identifiers on the hosted SwiftUI content. Check that the cell itself does not create a duplicate accessibility element. Verify Dynamic Type self-sizing, VoiceOver focus after snapshot updates, Switch Control ordering, Reduce Motion, and keyboard navigation where applicable.
