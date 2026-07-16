# Scroll semantics

## Model intent, not incidental callbacks

Represent at least these states:

- Whether real content has been displayed for the current content identity.
- Whether the viewport was bottom-pinned before an update.
- Whether the user is tracking, dragging, or decelerating.
- Whether a programmatic scroll animation is active.
- Which visible item and intra-item offset anchor an unpinned viewport when structure changes above it.

Reset this state when the session or other content identity changes.

## Calculate the bottom against adjusted insets

Use the effective scroll range rather than an exact equality:

```swift
let bottomOffsetY = max(
    -scrollView.adjustedContentInset.top,
    scrollView.contentSize.height
        - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
)
let distanceFromBottom = max(0, bottomOffsetY - scrollView.contentOffset.y)
let isBottomPinned = distanceFromBottom <= tolerance
```

Choose and test a small tolerance that survives fractional points and estimated-height correction. Recalculate after bounds, safe-area, keyboard, and content-inset changes. Handle short content deliberately; `scrollToItem` does not by itself reproduce SwiftUI's bottom default anchor when all content fits.

## Define update policy

| Event | Expected policy |
| --- | --- |
| Initial nonempty snapshot | Apply without animation, complete layout, then position at the bottom once |
| Append while bottom-pinned | Apply the update and remain bottom-pinned using the chosen animation policy |
| Streaming growth while bottom-pinned | Reconfigure the row and keep its bottom visible without fighting active touch interaction |
| Any update while scrolled away | Preserve the visible item and its intra-item offset; do not jump to the bottom |
| Insert or expansion above viewport | Restore the visible anchor after layout |
| Session/content replacement | Reset anchors and perform the new initial-placement policy |
| User drag or deceleration | Treat user intent as authoritative; avoid starting competing automatic scrolls |

Run programmatic scrolling only after the snapshot contains the target and layout has produced its attributes. Prefer the diffable apply completion and a synchronous layout pass over `Task.yield`, `DispatchQueue.main.async`, or repeated delayed retries.

Use `scrollViewDidEndScrollingAnimation` and interaction callbacks to finish or cancel programmatic state. Decide what a new update does to an in-flight animation rather than stacking animations blindly.

## Preserve an unpinned viewport

Capture a stable visible item ID plus the distance between its layout attribute and the viewport before applying a structural change. After the update and layout, locate the same ID and compensate the content offset by the geometry delta. Fall back to another surviving visible ID if the anchor was deleted.

For content growth in the visible streaming row, preserve the viewport unless it was bottom-pinned. Do not use content-height deltas as the only strategy when estimated sizes, insets, or deletions can change simultaneously.

## Match product behavior

Set `keyboardDismissMode = .interactive` when matching SwiftUI interactive dismissal. Preserve scroll-indicator and edge-effect choices. Verify rotation, Split View resizing, Dynamic Type changes, safe-area-bar changes, VoiceOver focus, and Reduce Motion because each can change geometry or permitted animation.
