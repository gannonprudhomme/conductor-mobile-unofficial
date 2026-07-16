# Verification

## Establish parity

Keep the old implementation runnable as a baseline while validating the replacement. Use a separate named DerivedData path when necessary; never clear existing DerivedData without explicit permission.

Exercise the same seeded data and actions against both implementations:

1. Empty, short, and long initial content.
2. Initial bottom placement with and without the keyboard.
3. Append and active streaming while bottom-pinned.
4. Active streaming after scrolling away from the bottom.
5. Expansion or insertion above, inside, and below the viewport.
6. Session replacement and rapid navigation between sessions.
7. Interactive keyboard dismissal, rotation, resizing, and Dynamic Type changes.
8. VoiceOver focus, accessibility actions, Reduce Motion, and retained accessibility identifiers.
9. Interrupted programmatic scrolling and immediate user drag.

Use simulator-only `simctl` and XCUITest automation for repeatable screenshots or video. Do not synthesize host mouse or keyboard input.

## Test at three levels

- Unit-test pure snapshot classification and scroll-policy decisions with Swift Testing.
- Integration-test controller rendering, identity preservation, and important offset transitions where practical.
- Use XCUITest for behavior visible to a person, relying on the same accessibility identifiers as the baseline.

Do not assert private cell counts or framework timing details unless they are the behavior under test.

## Measure performance

Form a specific hypothesis before profiling, such as reduced main-thread row construction or fewer scroll hitches during streaming. Match device, OS, build configuration, dataset, starting state, gestures, update cadence, and trial duration.

Use the most relevant Instruments:

- Animation Hitches or Core Animation for missed-frame behavior.
- Time Profiler for main-thread CPU and expensive cell or SwiftUI work.
- Allocations for retained hosting content and reuse behavior.
- The SwiftUI instrument for hosted row body and platform-view updates.
- Points of Interest or signposts for snapshot application and streaming-update latency when existing data is insufficient.

Use simulator traces to diagnose behavior, not to claim device performance. Prefer repeated, release-like runs on a physical device for comparative claims. Report distributions or repeated observations, not one favorable run.

Do not claim that UIKit is faster because it uses reuse or because scrolling feels better. State what improved, under which scenario, and by which metric. Keep the SwiftUI implementation when evidence does not show a meaningful benefit.
